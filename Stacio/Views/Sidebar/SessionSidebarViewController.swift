import AppKit
import StacioCoreBindings

@MainActor
public final class SessionSidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let sessionStore: SessionSidebarStoring?
    private let onOpenSession: (SessionRecord) throws -> Void
    private let sessionEditor: SessionSidebarSessionEditing
    private let sessionDeleteConfirmer: SessionSidebarSessionDeleteConfirming
    private let operationsPresenter: SessionSidebarOperationsPresenting
    private let errorPresenter: SessionSidebarErrorPresenting
    private let credentialCleaner: SessionSidebarCredentialCleaning?
    private let remoteEditCacheCleaner: RemoteEditSessionCacheClearing?
    private let hostPinger: SessionSidebarHostPinging
    private let shortcutCreator: SessionSidebarShortcutCreating
    private let defaultPresetStore: SessionSidebarDefaultPresetStoring
    private let settingsCopier: SessionSidebarSettingsCopying
    private let quickConnectPromptPrefillStore: QuickConnectPromptPrefillStore
    private let clipboardDismissalStore: QuickConnectClipboardDismissalStore
    private var activePingRuns: [String: SessionSidebarPingRunning] = [:]
    private var activePingPresenters: [String: SessionSidebarPingProgressPresenting] = [:]
    private var allNodes: [NSObject] = []
    private var nodes: [NSObject] = []
    private var searchQuery = ""
    private weak var newGroupButton: NSButton?
    private weak var clipboardSuggestionBanner: SessionSidebarClipboardSuggestionBannerView?
    private var currentClipboardSuggestion: QuickConnectParsedSSHCommand?
    private var clipboardDismissWorkItem: DispatchWorkItem?
    private var appActivationObserver: NSObjectProtocol?
    public let outlineView = NSOutlineView()
    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu(title: L10n.Sidebar.sessions)
        menu.delegate = self
        return menu
    }()

    public init(
        sessionStore: SessionSidebarStoring? = nil,
        onOpenSession: @escaping (SessionRecord) throws -> Void = { _ in },
        sessionEditor: SessionSidebarSessionEditing? = nil,
        sessionDeleteConfirmer: SessionSidebarSessionDeleteConfirming? = nil,
        operationsPresenter: SessionSidebarOperationsPresenting? = nil,
        errorPresenter: SessionSidebarErrorPresenting? = nil,
        credentialCleaner: SessionSidebarCredentialCleaning? = nil,
        remoteEditCacheCleaner: RemoteEditSessionCacheClearing? = RemoteEditCache.defaultCache(),
        hostPinger: SessionSidebarHostPinging = SystemSessionSidebarHostPinger(),
        shortcutCreator: SessionSidebarShortcutCreating = WeblocSessionSidebarShortcutCreator(),
        defaultPresetStore: SessionSidebarDefaultPresetStoring = UserDefaultsSessionSidebarDefaultPresetStore(),
        settingsCopier: SessionSidebarSettingsCopying = PasteboardSessionSidebarSettingsCopier(),
        quickConnectPromptPrefillStore: QuickConnectPromptPrefillStore = QuickConnectPromptPrefillStore(),
        clipboardDismissalStore: QuickConnectClipboardDismissalStore = QuickConnectClipboardDismissalStore()
    ) {
        self.sessionStore = sessionStore
        self.onOpenSession = onOpenSession
        self.sessionEditor = sessionEditor ?? AppKitSessionSidebarSessionEditor()
        self.sessionDeleteConfirmer = sessionDeleteConfirmer ?? AppKitSessionSidebarSessionDeleteConfirmation()
        self.operationsPresenter = operationsPresenter ?? AppKitSessionSidebarOperationsPresenter()
        self.errorPresenter = errorPresenter ?? AppKitSessionSidebarErrorPresenter()
        self.credentialCleaner = credentialCleaner
        self.remoteEditCacheCleaner = remoteEditCacheCleaner
        self.hostPinger = hostPinger
        self.shortcutCreator = shortcutCreator
        self.defaultPresetStore = defaultPresetStore
        self.settingsCopier = settingsCopier
        self.quickConnectPromptPrefillStore = quickConnectPromptPrefillStore
        self.clipboardDismissalStore = clipboardDismissalStore
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

        let titleRow = SessionSidebarHeaderHoverView(actionButton: addGroupButton)
        titleRow.setAccessibilityIdentifier("Stacio.Sidebar.sessionTitleRow")
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(titleLabel)
        titleRow.addSubview(addGroupButton)
        NSLayoutConstraint.activate([
            titleRow.heightAnchor.constraint(equalToConstant: 30),
            titleLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            addGroupButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            addGroupButton.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            addGroupButton.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor)
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
        outlineView.menu = contextMenu
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

        container.addSubview(header)
        container.addSubview(sessionTree)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),

            sessionTree.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sessionTree.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sessionTree.topAnchor.constraint(equalTo: header.bottomAnchor),
            sessionTree.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        header.arrangedSubviews.forEach { arrangedSubview in
            arrangedSubview.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -16).isActive = true
        }

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

    public var sessionOutlineTextSnapshot: String {
        nodes.flatMap(textSnapshot(for:))
        .joined(separator: "\n")
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
            return folder.folders.count + folder.sessions.count
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
            if index < folder.folders.count {
                return folder.folders[index]
            }
            return folder.sessions[index - folder.folders.count]
        }
        return nodes[index]
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

        let iconDescriptor = sessionProtocolIconDescriptor(for: session.session.protocol)
        let iconView = makeRowIcon(
            symbolName: iconDescriptor.symbolName,
            accessibilityDescription: iconDescriptor.accessibilityDescription,
            identifier: "Stacio.Sidebar.sessionProtocolIcon"
        )

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

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === contextMenu else {
            return
        }
        menu.removeAllItems()
        if let session = contextMenuSession() {
            for item in makeContextMenu(for: session).items {
                menu.addItem(item)
            }
            return
        }
        if let folder = contextMenuFolder() {
            for item in makeContextMenu(for: folder).items {
                menu.addItem(item)
            }
        }
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

    private func contextMenuSession() -> SessionRecord? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SessionSidebarSessionNode
        else {
            return nil
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return node.session
    }

    private func contextMenuFolder() -> SessionSidebarFolderNode? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? SessionSidebarFolderNode,
              node.folder != nil
        else {
            return nil
        }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return node
    }

    private func makeContextMenu(for session: SessionRecord) -> NSMenu {
        let menu = NSMenu(title: session.name)
        [
            (L10n.Sidebar.executeSession, SessionSidebarContextMenuAction.execute),
            (L10n.Sidebar.connectAs, .connectAs),
            (L10n.Sidebar.pingHost, .pingHost)
        ].forEach { title, action in
            menu.addItem(makeContextMenuItem(title: title, action: action, session: session))
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
            ) else {
                return
            }
            _ = try sessionStore.moveSession(id: session.id, targetFolderID: destination.folderID)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .moveSession, parentWindow: view.window)
        }
    }

    private func exportSessions() {
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
              let folder = folderNode.folder,
              operationsPresenter.confirmDeleteFolder(folder, parentWindow: view.window)
        else {
            return
        }

        do {
            try sessionStore.deleteFolder(id: folder.id)
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .deleteFolder, parentWindow: view.window)
        }
    }

    private func exportFolder(_ folderNode: SessionSidebarFolderNode) {
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
        guard let sessionStore,
              !sessions.isEmpty,
              sessionDeleteConfirmer.shouldDeleteSessions(sessions, parentWindow: view.window)
        else {
            return
        }

        do {
            for session in sessions {
                try sessionStore.deleteSession(id: session.id)
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
            reloadSessionNodes()
        } catch {
            errorPresenter.present(error, context: .deleteSession, parentWindow: view.window)
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
              )
        else {
            return
        }
        do {
            let json = try singleSessionJSON(session, store: sessionStore)
            try json.write(to: destinationURL, atomically: true, encoding: .utf8)
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

    private func reloadSessionNodes() {
        allNodes = makeSessionNodes()
        applySearchFilter()
    }

    private func applySearchFilter() {
        nodes = filteredNodes(from: allNodes, query: searchQuery)
        outlineView.reloadData()
        expandFolderNodes(nodes)
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
        let folders = folder.folders.compactMap { filteredNode($0, query: query) }
        let sessions = folder.sessions.filter { $0.matchesSearchQuery(query) }
        guard !folders.isEmpty || !sessions.isEmpty else {
            return nil
        }
        return folder.copy(folders: folders, sessions: sessions)
    }

    private func makeSessionNodes() -> [NSObject] {
        guard let sessionStore else {
            return ["收藏", "生产", "开发"].map { title in
                SessionSidebarFolderNode(title: title, sessions: [])
            }
        }

        do {
            let folders = try sessionStore.listFolders()
            let rootSessions = try sessionStore.listSessions(folderID: nil)
            var sessionsByFolderID: [String?: [SessionRecord]] = [nil: rootSessions]
            var loadedSessions = rootSessions
            for folder in folders {
                let sessions = try sessionStore.listSessions(folderID: folder.id)
                sessionsByFolderID[folder.id] = sessions
                loadedSessions.append(contentsOf: sessions)
            }
            var loadedNodes: [NSObject] = rootSessions.map { SessionSidebarSessionNode(session: $0) }
            loadedNodes.append(
                contentsOf: makeFolderNodes(
                    parentID: nil,
                    folders: folders,
                    sessionsByFolderID: sessionsByFolderID
                )
            )
            let virtualNodes = virtualSessionNodes(from: loadedSessions).map { $0 as NSObject }
            return virtualNodes + loadedNodes
        } catch {
            return []
        }
    }

    private func makeFolderNodes(
        parentID: String?,
        folders: [SessionFolder],
        sessionsByFolderID: [String?: [SessionRecord]]
    ) -> [SessionSidebarFolderNode] {
        folders
            .filter { $0.parentId == parentID }
            .map { folder in
                SessionSidebarFolderNode(
                    folder: folder,
                    folders: makeFolderNodes(
                        parentID: folder.id,
                        folders: folders,
                        sessionsByFolderID: sessionsByFolderID
                    ),
                    sessions: (sessionsByFolderID[folder.id] ?? []).map { SessionSidebarSessionNode(session: $0) }
                )
            }
    }

    private func virtualSessionNodes(from sessions: [SessionRecord]) -> [SessionSidebarFolderNode] {
        let recent = recentSessionNodes(from: sessions)
        let favorites = sessions.filter { session in
            session.tags.contains { tag in
                let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "favorite" || normalized == "favorites" || normalized == "收藏"
            }
        }
        var nodes: [SessionSidebarFolderNode] = []
        if !recent.isEmpty {
            nodes.append(
                SessionSidebarFolderNode(
                    title: "Recent",
                    sessions: recent,
                    isHiddenFromTextSnapshot: true
                )
            )
        }
        if !favorites.isEmpty {
            nodes.append(
                SessionSidebarFolderNode(
                    title: L10n.Sidebar.favorites,
                    sessions: favorites.map { SessionSidebarSessionNode(session: $0) }
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
            .map { SessionSidebarSessionNode(session: $0.session, displayStyle: .recent(lastOpenedAt: $0.date)) }
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
            expandFolderNodes(folder.folders)
        }
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
    let folders: [SessionSidebarFolderNode]
    let sessions: [SessionSidebarSessionNode]
    let isHiddenFromTextSnapshot: Bool

    var id: String? {
        folder?.id
    }

    init(
        folder: SessionFolder,
        folders: [SessionSidebarFolderNode],
        sessions: [SessionSidebarSessionNode]
    ) {
        self.folder = folder
        title = folder.name
        self.folders = folders
        self.sessions = sessions
        isHiddenFromTextSnapshot = false
    }

    init(
        title: String,
        folders: [SessionSidebarFolderNode] = [],
        sessions: [SessionSidebarSessionNode],
        isHiddenFromTextSnapshot: Bool = false
    ) {
        folder = nil
        self.title = title
        self.folders = folders
        self.sessions = sessions
        self.isHiddenFromTextSnapshot = isHiddenFromTextSnapshot
    }

    var textSnapshot: [String] {
        guard isHiddenFromTextSnapshot == false else {
            return []
        }
        return [title]
            + folders.flatMap(\.textSnapshot)
            + sessions.flatMap { [$0.title, $0.subtitle] }
    }

    var allSessionNodes: [SessionSidebarSessionNode] {
        sessions + folders.flatMap(\.allSessionNodes)
    }

    func copy(
        folders: [SessionSidebarFolderNode],
        sessions: [SessionSidebarSessionNode]
    ) -> SessionSidebarFolderNode {
        if let folder {
            return SessionSidebarFolderNode(folder: folder, folders: folders, sessions: sessions)
        }
        return SessionSidebarFolderNode(
            title: title,
            folders: folders,
            sessions: sessions,
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
    private let displayStyle: DisplayStyle

    init(session: SessionRecord, displayStyle: DisplayStyle = .normal) {
        self.session = session
        self.displayStyle = displayStyle
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
