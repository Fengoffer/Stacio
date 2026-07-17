import AppKit
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class SessionSidebarViewControllerTests: XCTestCase {
    func testSSHSessionRowUsesSavedManualIcon() throws {
        let session = SessionRecord(
            id: "session_icon",
            folderId: nil,
            name: "Ubuntu Server",
            protocol: "ssh",
            host: "ubuntu.example.com",
            port: 22,
            username: "root",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]],
            configJSONByID: ["session_icon": #"{"sessionIconID":"ubuntu"}"#]
        )
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        XCTAssertEqual(controller.manualSessionIconIDForTesting(sessionID: "session_icon"), "ubuntu")
        XCTAssertEqual(controller.sessionIconForTesting(sessionID: "session_icon")?.accessibilityDescription, "Ubuntu")
    }

    func testUnknownManualIconFallsBackToSSHProtocolIcon() {
        let session = SessionRecord(
            id: "session_unknown_icon",
            folderId: nil,
            name: "Legacy Server",
            protocol: "ssh",
            host: "legacy.example.com",
            port: 22,
            username: "root",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]],
            configJSONByID: ["session_unknown_icon": #"{"sessionIconID":"removed"}"#]
        )
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        XCTAssertNil(controller.manualSessionIconIDForTesting(sessionID: "session_unknown_icon"))
        XCTAssertNil(controller.sessionIconForTesting(sessionID: "session_unknown_icon"))
    }

    func testSidebarExposesDocumentNavigationAndSessionList() {
        let controller = SessionSidebarViewController()

        controller.loadView()

        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.header"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.a2SessionTree"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.a2Footer"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.editSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.duplicateSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.moveSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.exportSessions"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.deleteSession"))
        let searchField = controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.search") as? NSSearchField

        XCTAssertEqual(searchField?.placeholderString, "搜索会话、主机或标签")
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.sessionOutline"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.a2QuickActions"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.compactQuickActions"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.quickConnect"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.quickConnectFooter"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.quickConnectTemplate"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.newSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.import"))
        XCTAssertEqual(controller.outlineView.style, .sourceList)
        XCTAssertEqual(controller.outlineView.rowHeight, 44)
        XCTAssertEqual(controller.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual((controller.view as? NSVisualEffectView)?.material, .sidebar)
        XCTAssertNil(controller.view.layer?.backgroundColor)
    }

    func testSidebarUsesFlushMacOSSourceListSurfaceWithoutCardChrome() throws {
        let controller = SessionSidebarViewController()

        controller.loadView()

        XCTAssertEqual(controller.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(controller.view.layer?.borderWidth ?? 0, 0)
        XCTAssertEqual((controller.view as? NSVisualEffectView)?.material, .sidebar)
        XCTAssertNil(controller.view.layer?.backgroundColor)
    }

    func testSidebarDoesNotExposeSessionManagementToolbarInSourceList() throws {
        let controller = SessionSidebarViewController()

        controller.loadView()

        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.a2Footer"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.editSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.duplicateSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.moveSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.exportSessions"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.deleteSession"))
    }

    func testSidebarHeaderUsesSearchOnlySourceListChrome() throws {
        let controller = SessionSidebarViewController()

        controller.loadView()

        let header = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.header")
        )
        let searchField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.search") as? NSSearchField
        )

        XCTAssertEqual(header.layer?.borderWidth ?? 0, 0)
        XCTAssertLessThanOrEqual(header.frame.height, 76)
        XCTAssertEqual((header as? NSStackView)?.edgeInsets.left, 8)
        XCTAssertEqual(searchField.placeholderString, "搜索会话、主机或标签")
        XCTAssertEqual(searchField.focusRingType, .default)
        XCTAssertEqual(searchField.layer?.borderWidth ?? 0, 0)
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.compactQuickActions"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.quickConnect"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.newSession"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.import"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.newGroup"))
        XCTAssertTrue(controller.isNewGroupButtonHiddenForTesting)
        XCTAssertEqual(controller.outlineView.backgroundColor, .clear)
    }

    func testSidebarHeaderRespectsWindowSafeAreaBelowTrafficLights() throws {
        let controller = SessionSidebarViewController()

        controller.loadView()

        let header = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.header")
        )
        let safeAreaTopConstraint = try XCTUnwrap(
            controller.view.constraints.first { constraint in
                constraint.firstItem === header
                    && constraint.firstAttribute == .top
                    && constraint.secondItem === controller.view.safeAreaLayoutGuide
                    && constraint.secondAttribute == .top
            }
        )

        XCTAssertEqual(safeAreaTopConstraint.constant, 8)
    }

    func testSidebarDoesNotExposeConnectionOrImportActionsInNavigationPane() throws {
        let controller = SessionSidebarViewController()

        controller.loadView()

        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.quickConnect"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.import"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.newSession"))
    }

    func testOpenSessionErrorPresentationUsesChineseDiagnosticInsteadOfGeneratedEnum() {
        let message = SessionSidebarErrorContext.openSession.informativeText(
            for: SshRuntimeError.Transport(message: "[Session(-37)] Would block")
        )

        XCTAssertEqual(message, "SSH 通道暂时不可用，请稍后重试")
        XCTAssertFalse(message.contains("StacioCoreBindings"))
        XCTAssertFalse(message.contains("SshRuntimeError"))
        XCTAssertFalse(message.contains("Transport"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("Would block"))
    }

    func testSidebarLoadsPersistedFoldersAndSessionsFromStore() throws {
        let folder = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let session = SessionRecord(
            id: "session_api",
            folderId: folder.id,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [folder],
            sessionsByFolderID: [folder.id: [session]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        XCTAssertEqual(store.events, ["snapshot"])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "Production\nAPI Server\ndeploy@api.example.com:22")
        XCTAssertEqual(controller.outlineRootCount, 1)
        XCTAssertEqual(controller.outlineView.rowHeight, 44)

        let folderItem = controller.outlineView(controller.outlineView, child: 0, ofItem: nil)
        let sessionItem = controller.outlineView(controller.outlineView, child: 0, ofItem: folderItem)
        let sessionCell = try XCTUnwrap(
            controller.outlineView(controller.outlineView, viewFor: nil, item: sessionItem)
        )
        XCTAssertEqual(sessionCell.textFieldSnapshot, ["API Server", "deploy@api.example.com:22"])

        let folderCell = try XCTUnwrap(
            controller.outlineView(controller.outlineView, viewFor: nil, item: folderItem)
        )
        XCTAssertNotNil(folderCell.firstSubview(withIdentifier: "Stacio.Sidebar.folderContainer"))
        let folderIcon = try XCTUnwrap(
            folderCell.firstSubview(withIdentifier: "Stacio.Sidebar.folderIcon") as? NSImageView
        )
        XCTAssertEqual(folderIcon.image?.accessibilityDescription, "分组")

        let protocolIcon = try XCTUnwrap(
            sessionCell.firstSubview(withIdentifier: "Stacio.Sidebar.sessionProtocolIcon") as? NSImageView
        )
        XCTAssertEqual(protocolIcon.image?.accessibilityDescription, "SSH")
        XCTAssertEqual(protocolIcon.contentTintColor, StacioDesignSystem.theme.secondaryTextColor)
    }

    func testSidebarShowsDisclosureForEmptyPersistedFolder() throws {
        let folder = SessionFolder(id: "folder_empty", parentId: nil, name: "Empty Group")
        let store = RecordingSessionSidebarStore(folders: [folder])
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        let folderItem = controller.outlineView(controller.outlineView, child: 0, ofItem: nil)
        XCTAssertEqual(controller.outlineView(controller.outlineView, numberOfChildrenOfItem: folderItem), 0)
        XCTAssertTrue(controller.outlineView(controller.outlineView, isItemExpandable: folderItem))
    }

    func testSidebarSessionProtocolIconsDistinguishCommonSessionTypes() throws {
        let sessions = [
            makeSession(id: "ssh", protocolName: "ssh", name: "SSH"),
            makeSession(id: "serial", protocolName: "serial", name: "Serial"),
            makeSession(id: "vnc", protocolName: "vnc", name: "VNC"),
            makeSession(id: "scp", protocolName: "scp", name: "SCP"),
            makeSession(id: "ftp", protocolName: "ftp", name: "FTP"),
            makeSession(id: "telnet", protocolName: "telnet", name: "Telnet"),
            makeSession(id: "browser", protocolName: "browser", name: "Browser"),
            makeSession(id: "file", protocolName: "file", name: "File"),
            makeSession(id: "shell", protocolName: "shell", name: "Shell"),
            makeSession(id: "prd", protocolName: "prd", name: "PRD")
        ]
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: sessions]
        )
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        let expectedLabels = ["SSH", "串口", "VNC", "SCP", "FTP", "Telnet", "浏览器", "文件", "Shell", "PRD"]
        var labels: [String] = []
        for index in sessions.indices {
            let sessionItem = controller.outlineView(controller.outlineView, child: index, ofItem: nil)
            let cell = try XCTUnwrap(
                controller.outlineView(controller.outlineView, viewFor: nil, item: sessionItem)
            )
            let icon = try XCTUnwrap(
                cell.firstSubview(withIdentifier: "Stacio.Sidebar.sessionProtocolIcon") as? NSImageView
            )
            labels.append(icon.image?.accessibilityDescription ?? "")
        }

        XCTAssertEqual(labels, expectedLabels)
    }

    func testSidebarKeepsUngroupedSessionsAtRootBesideFoldersWithAlignedIcons() throws {
        let folder = SessionFolder(id: "folder_test", parentId: nil, name: "test")
        let session = SessionRecord(
            id: "session_201",
            folderId: nil,
            name: "192.168.1.201",
            protocol: "ssh",
            host: "192.168.1.201",
            port: 22,
            username: "root",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [folder],
            sessionsByFolderID: [nil: [session]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        XCTAssertEqual(controller.outlineRootCount, 2)
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "192.168.1.201\nroot@192.168.1.201:22\ntest")

        let rootSessionItem = controller.outlineView(controller.outlineView, child: 0, ofItem: nil)
        let rootFolderItem = controller.outlineView(controller.outlineView, child: 1, ofItem: nil)
        XCTAssertEqual(controller.outlineView(controller.outlineView, numberOfChildrenOfItem: rootSessionItem), 0)
        XCTAssertFalse(controller.outlineView(controller.outlineView, isItemExpandable: rootSessionItem))
        XCTAssertTrue(controller.outlineView(controller.outlineView, isItemExpandable: rootFolderItem))

        let sessionCell = try XCTUnwrap(
            controller.outlineView(controller.outlineView, viewFor: nil, item: rootSessionItem)
        )
        let folderCell = try XCTUnwrap(
            controller.outlineView(controller.outlineView, viewFor: nil, item: rootFolderItem)
        )
        XCTAssertEqual(sessionCell.textFieldSnapshot, ["192.168.1.201", "root@192.168.1.201:22"])
        XCTAssertEqual(folderCell.textFieldSnapshot, ["test"])

        sessionCell.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
        folderCell.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
        sessionCell.layoutSubtreeIfNeeded()
        folderCell.layoutSubtreeIfNeeded()

        let sessionIcon = try XCTUnwrap(
            sessionCell.firstSubview(withIdentifier: "Stacio.Sidebar.sessionProtocolIcon") as? NSImageView
        )
        let folderIcon = try XCTUnwrap(
            folderCell.firstSubview(withIdentifier: "Stacio.Sidebar.folderIcon") as? NSImageView
        )
        let sessionIconLeading = sessionIcon.convert(sessionIcon.bounds, to: sessionCell).minX
        let folderIconLeading = folderIcon.convert(folderIcon.bounds, to: folderCell).minX
        XCTAssertGreaterThan(sessionIconLeading, 0)
        XCTAssertGreaterThan(folderIconLeading, 0)
        XCTAssertEqual(sessionIconLeading, folderIconLeading, accuracy: 0.5)
    }

    func testSelectedFolderCellUsesSingleSystemSelectionWithoutInnerCardFill() throws {
        let folder = SessionFolder(id: "folder_test", parentId: nil, name: "test")
        let store = RecordingSessionSidebarStore(folders: [folder])
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        let folderItem = controller.outlineView(controller.outlineView, child: 0, ofItem: nil)
        let folderCell = try XCTUnwrap(
            controller.outlineView(controller.outlineView, viewFor: nil, item: folderItem) as? NSTableCellView
        )
        let container = try XCTUnwrap(
            folderCell.firstSubview(withIdentifier: "Stacio.Sidebar.folderContainer")
        )
        let folderIcon = try XCTUnwrap(
            folderCell.firstSubview(withIdentifier: "Stacio.Sidebar.folderIcon") as? NSImageView
        )

        XCTAssertNotNil(container.layer?.backgroundColor)
        XCTAssertEqual(container.layer?.borderWidth, 1)
        XCTAssertEqual(folderIcon.contentTintColor, StacioDesignSystem.theme.accentColor)
        XCTAssertEqual(folderCell.textField?.textColor, StacioDesignSystem.theme.primaryTextColor)

        folderCell.backgroundStyle = .emphasized

        XCTAssertNil(container.layer?.backgroundColor)
        XCTAssertNil(container.layer?.borderColor)
        XCTAssertEqual(container.layer?.borderWidth, 0)
        XCTAssertEqual(folderIcon.contentTintColor, .alternateSelectedControlTextColor)
        XCTAssertEqual(folderCell.textField?.textColor, .alternateSelectedControlTextColor)
    }

    func testSidebarLoadsNestedSessionFoldersAtLeastThreeLevels() throws {
        let production = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let database = SessionFolder(id: "folder_db", parentId: production.id, name: "Database")
        let primary = SessionFolder(id: "folder_primary", parentId: database.id, name: "Primary")
        let session = SessionRecord(
            id: "session_db",
            folderId: primary.id,
            name: "Primary DB",
            protocol: "ssh",
            host: "db.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [production, database, primary],
            sessionsByFolderID: [primary.id: [session]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        XCTAssertEqual(store.events, ["snapshot"])
        XCTAssertEqual(
            controller.sessionOutlineTextSnapshot,
            "Production\nDatabase\nPrimary\nPrimary DB\ndeploy@db.example.com:22"
        )

        let productionItem = controller.outlineView(controller.outlineView, child: 0, ofItem: nil)
        let databaseItem = controller.outlineView(controller.outlineView, child: 0, ofItem: productionItem)
        let primaryItem = controller.outlineView(controller.outlineView, child: 0, ofItem: databaseItem)
        let sessionItem = controller.outlineView(controller.outlineView, child: 0, ofItem: primaryItem)
        XCTAssertEqual(controller.outlineView(controller.outlineView, numberOfChildrenOfItem: productionItem), 1)
        XCTAssertEqual(controller.outlineView(controller.outlineView, numberOfChildrenOfItem: databaseItem), 1)
        XCTAssertEqual(controller.outlineView(controller.outlineView, numberOfChildrenOfItem: primaryItem), 1)
        let sessionCell = try XCTUnwrap(
            controller.outlineView(controller.outlineView, viewFor: nil, item: sessionItem)
        )
        XCTAssertEqual(sessionCell.textFieldSnapshot, ["Primary DB", "deploy@db.example.com:22"])
    }

    func testNewGroupButtonIsHiddenUntilSessionHeaderHover() {
        let controller = SessionSidebarViewController()

        controller.loadView()

        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.newGroup"))
        XCTAssertTrue(controller.isNewGroupButtonHiddenForTesting)
    }

    func testNewGroupButtonShowsOnlyWhileSessionHeaderIsHovered() throws {
        let controller = SessionSidebarViewController()

        controller.loadView()
        let titleRow = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.sessionTitleRow")
        )

        XCTAssertTrue(controller.isNewGroupButtonHiddenForTesting)

        titleRow.mouseEntered(with: makeSidebarHoverEvent(type: .mouseEntered))

        XCTAssertFalse(controller.isNewGroupButtonHiddenForTesting)

        titleRow.mouseExited(with: makeSidebarHoverEvent(type: .mouseExited))

        XCTAssertTrue(controller.isNewGroupButtonHiddenForTesting)
    }

    func testNewGroupButtonActionCreatesRootGroup() {
        let store = RecordingSessionSidebarStore(folders: [])
        let operations = RecordingSessionSidebarOperationsPresenter(createFolderName: "Production")
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performAddRootFolderForTesting()

        XCTAssertEqual(operations.createFolderParentIDs, [nil])
        XCTAssertEqual(store.createdFolderRequests.map(\.parentID), [nil])
        XCTAssertEqual(store.createdFolderRequests.map(\.name), ["Production"])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "Production")
    }

    func testFolderContextMenuMatchesRequestedActions() {
        let folder = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let store = RecordingSessionSidebarStore(folders: [folder])
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        XCTAssertEqual(
            controller.folderContextMenuTitlesForTesting(folderID: "folder_prod"),
            [
                "新建分组",
                "重命名分组",
                "删除分组",
                "导出分组会话"
            ]
        )
    }

    func testFolderContextActionsCreateRenameExportAndDeleteGroups() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let folder = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let store = RecordingSessionSidebarStore(
            folders: [folder],
            folderExportJSON: #"{"format":"stacio.sessions.v1","folders":[],"sessions":[]}"#
        )
        let operations = RecordingSessionSidebarOperationsPresenter(
            createFolderName: "Database",
            renameFolderValue: "Prod",
            folderExportURL: destinationURL
        )
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performFolderContextMenuActionForTesting(.createChild, folderID: "folder_prod")
        controller.performFolderContextMenuActionForTesting(.rename, folderID: "folder_prod")
        controller.performFolderContextMenuActionForTesting(.export, folderID: "folder_prod")
        controller.performFolderContextMenuActionForTesting(.delete, folderID: "folder_prod")

        XCTAssertEqual(operations.createFolderParentIDs, ["folder_prod"])
        XCTAssertEqual(store.createdFolderRequests.map(\.parentID), ["folder_prod"])
        XCTAssertEqual(store.createdFolderRequests.map(\.name), ["Database"])
        XCTAssertEqual(operations.renameFolderRequestIDs, ["folder_prod"])
        XCTAssertEqual(store.renamedFolderRequests.map(\.name), ["Prod"])
        XCTAssertEqual(operations.folderExportRequestIDs, ["folder_prod"])
        XCTAssertEqual(store.exportedFolderIDs, ["folder_prod"])
        XCTAssertEqual(operations.completedExportURLs, [destinationURL])
        XCTAssertEqual(try String(contentsOf: destinationURL), #"{"format":"stacio.sessions.v1","folders":[],"sessions":[]}"#)
        XCTAssertEqual(operations.deleteFolderRequestIDs, ["folder_prod"])
        XCTAssertEqual(store.deletedFolderIDs, ["folder_prod"])
    }

    func testSidebarShowsFavoritesVirtualGroupWithoutRecentSectionWhenAvailable() {
        let favorite = SessionRecord(
            id: "session_favorite",
            folderId: nil,
            name: "堡垒机",
            protocol: "ssh",
            host: "jump.example.com",
            port: 22,
            username: "ops",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["favorite"],
            lastOpenedAt: nil
        )
        let recent = SessionRecord(
            id: "session_recent",
            folderId: nil,
            name: "最近 API",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: "2026-05-28T12:00:00Z"
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [favorite, recent]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)

        controller.loadView()

        XCTAssertEqual(
            controller.sessionOutlineTextSnapshot,
            "收藏\n堡垒机\nops@jump.example.com:22\n堡垒机\nops@jump.example.com:22\n最近 API\ndeploy@api.example.com:22"
        )
        XCTAssertFalse(controller.sessionOutlineTextSnapshot.contains("\n最近\n"))
    }

    func testRecentSessionsUseChineseTitleAndFollowThePersistedVisibilitySetting() {
        let suiteName = "StacioSidebarRecentSessionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let favorite = makeSession(
            id: "favorite",
            protocolName: "ssh",
            name: "Favorite",
            tags: ["favorite"]
        )
        let recent = SessionRecord(
            id: "session_recent",
            folderId: nil,
            name: "Recently Opened",
            protocol: "ssh",
            host: "recent.example.com",
            port: 22,
            username: "ops",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: "2026-07-15T12:00:00Z"
        )
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(
                folders: [],
                sessionsByFolderID: [nil: [favorite, recent]]
            ),
            settingsStore: settingsStore
        )
        controller.loadView()

        XCTAssertEqual(controller.virtualGroupTitlesForTesting, ["最近使用", "收藏"])

        settingsStore.update { settings in
            settings.sessionSidebarShowRecentSessions = false
        }

        XCTAssertEqual(controller.virtualGroupTitlesForTesting, ["收藏"])
        XCTAssertTrue(controller.sessionOutlineTextSnapshot.contains("Recently Opened"))
        XCTAssertTrue(controller.sessionOutlineTextSnapshot.contains("Favorite"))

        settingsStore.update { settings in
            settings.sessionSidebarShowRecentSessions = true
        }

        XCTAssertEqual(controller.virtualGroupTitlesForTesting, ["最近使用", "收藏"])
    }

    func testSearchFiltersSessionsByNameHostUserAndFolder() throws {
        let production = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let development = SessionFolder(id: "folder_dev", parentId: nil, name: "Development")
        let api = SessionRecord(
            id: "session_api",
            folderId: production.id,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let worker = SessionRecord(
            id: "session_worker",
            folderId: development.id,
            name: "Worker",
            protocol: "ssh",
            host: "worker.internal",
            port: 2222,
            username: "ops",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["dev"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [production, development],
            sessionsByFolderID: [
                production.id: [api],
                development.id: [worker]
            ]
        )
        let controller = SessionSidebarViewController(sessionStore: store)
        controller.loadView()

        try controller.performSearchForTesting("api")

        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "Production\nAPI Server\ndeploy@api.example.com:22")

        try controller.performSearchForTesting("ops")

        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "Development\nWorker\nops@worker.internal:2222")

        try controller.performSearchForTesting("production")

        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "Production\nAPI Server\ndeploy@api.example.com:22")

        try controller.performSearchForTesting("")

        XCTAssertEqual(
            controller.sessionOutlineTextSnapshot,
            "Production\nAPI Server\ndeploy@api.example.com:22\nDevelopment\nWorker\nops@worker.internal:2222"
        )
    }

    func testOpeningPersistedSessionRunsInjectedOpenAction() {
        let folder = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let session = SessionRecord(
            id: "session_api",
            folderId: folder.id,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [folder],
            sessionsByFolderID: [folder.id: [session]]
        )
        var opened: [SessionRecord] = []
        let controller = SessionSidebarViewController(
            sessionStore: store,
            onOpenSession: { opened.append($0) }
        )
        controller.loadView()

        controller.performOpenSessionForTesting(id: "session_api")

        XCTAssertEqual(opened, [session])
    }

    func testOpeningPersistedSessionPresentsOpenError() {
        let session = SessionRecord(
            id: "session_telnet",
            folderId: nil,
            name: "Legacy Router",
            protocol: "telnet",
            host: "router.example.com",
            port: 23,
            username: "admin",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let errorPresenter = RecordingSessionSidebarErrorPresenter()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            onOpenSession: { _ in throw TestSessionSidebarError.failed },
            errorPresenter: errorPresenter
        )
        controller.loadView()

        controller.performOpenSessionForTesting(id: "session_telnet")

        XCTAssertEqual(errorPresenter.contexts, [.openSession])
        XCTAssertEqual(errorPresenter.errors.count, 1)
    }

    func testSessionContextMenuMatchesRequestedActionsForSession() {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)
        controller.loadView()

        XCTAssertEqual(
            controller.contextMenuTitlesForTesting(id: "session_api"),
            [
                "执行",
                "连接为...",
                "Ping 主机",
                "-",
                "重命名会话",
                "编辑会话",
                "删除会话",
                "复制会话",
                "移动会话",
                "将会话保存到文件",
                "创建桌面快捷方式",
                "-",
                "将会话设置保存为默认预设",
                "复制会话设置"
            ]
        )
    }

    func testRecentAndFavoriteShortcutMenusOnlyExposeConnectionActions() {
        let suiteName = "StacioSidebarVirtualMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.sessionSidebarShowRecentSessions = true
        }
        let session = SessionRecord(
            id: "session_shortcut",
            folderId: nil,
            name: "Shortcut",
            protocol: "ssh",
            host: "shortcut.example.com",
            port: 22,
            username: "ops",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["favorite"],
            lastOpenedAt: "2026-07-15T12:00:00Z"
        )
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(
                folders: [],
                sessionsByFolderID: [nil: [session]]
            ),
            settingsStore: settingsStore
        )
        controller.loadView()

        let connectionActions = ["执行", "连接为...", "Ping 主机"]
        XCTAssertEqual(controller.contextMenuTitlesForTesting(row: 1), connectionActions)
        XCTAssertEqual(controller.contextMenuTitlesForTesting(row: 3), connectionActions)
    }

    func testContextMenuExecuteAndConnectAsOpenRealSessions() {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let operations = RecordingSessionSidebarOperationsPresenter(connectAsUsername: "root")
        var opened: [SessionRecord] = []
        let controller = SessionSidebarViewController(
            sessionStore: store,
            onOpenSession: { opened.append($0) },
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performContextMenuActionForTesting(.execute, id: "session_api")
        controller.performContextMenuActionForTesting(.connectAs, id: "session_api")

        XCTAssertEqual(opened.map(\.id), ["session_api", "session_api"])
        XCTAssertEqual(opened.map(\.username), ["deploy", "root"])
        XCTAssertEqual(store.updatedRequests.count, 0)
        XCTAssertEqual(operations.connectAsRequestSessionIDs, ["session_api"])
    }

    func testContextMenuPingHostStartsLiveProgressBeforeFinalResult() throws {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let pinger = RecordingSessionSidebarPinger()
        let operations = RecordingSessionSidebarOperationsPresenter()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations,
            hostPinger: pinger
        )
        controller.loadView()

        controller.performContextMenuActionForTesting(.pingHost, id: "session_api")

        XCTAssertEqual(pinger.hosts, ["api.example.com"])
        XCTAssertEqual(operations.pingProgressHosts, ["api.example.com"])
        XCTAssertEqual(operations.pingResults, [])
        let progressPresenter = try XCTUnwrap(operations.pingProgressPresenter)

        pinger.emitOutput("PING api.example.com (203.0.113.10): 56 data bytes\n")
        pinger.emitOutput("64 bytes from 203.0.113.10: icmp_seq=0 ttl=58 time=12.3 ms\n")
        XCTAssertEqual(progressPresenter.outputs, [
            "PING api.example.com (203.0.113.10): 56 data bytes\n",
            "64 bytes from 203.0.113.10: icmp_seq=0 ttl=58 time=12.3 ms\n"
        ])
        XCTAssertEqual(operations.retainedPingProgressPresenterCount, 1)

        let result = SessionSidebarPingResult(host: "api.example.com", reachable: true, output: "ok")
        pinger.finish(result)
        XCTAssertEqual(progressPresenter.finishedResults, [result])
        XCTAssertEqual(operations.pingResults, [])
        XCTAssertEqual(operations.retainedPingProgressPresenterCount, 1)

        progressPresenter.closeForTesting()
        XCTAssertEqual(operations.retainedPingProgressPresenterCount, 0)
    }

    func testSystemPingRunnerDeliversOutputBeforeCompletion() throws {
        let pinger = SystemSessionSidebarHostPinger(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: { _ in
                [
                    "-c",
                    "printf 'first ping line\\n'; sleep 0.2; printf 'second ping line\\n'"
                ]
            }
        )
        let firstOutput = expectation(description: "first output")
        let completionArrived = expectation(description: "completion")
        let recorder = RecordingLivePingOutput()

        _ = try pinger.ping(
            host: "ignored.example.com",
            onOutput: { text in
                recorder.outputs.append(text)
                if text.contains("first ping line") {
                    firstOutput.fulfill()
                }
            },
            completion: { result in
                recorder.completed = true
                switch result {
                case let .success(pingResult):
                    recorder.results.append(pingResult)
                case let .failure(error):
                    recorder.errors.append(error)
                }
                completionArrived.fulfill()
            }
        )

        wait(for: [firstOutput], timeout: 2)
        XCTAssertFalse(recorder.completed)
        wait(for: [completionArrived], timeout: 2)
        XCTAssertTrue(recorder.outputs.joined().contains("second ping line"))
        XCTAssertEqual(recorder.results.first?.reachable, true)
    }

    func testSystemPingRunnerPreservesTerminalPingLineBreaks() throws {
        let pinger = SystemSessionSidebarHostPinger(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: { _ in
                [
                    "-c",
                    """
                    printf 'PING 192.168.1.201 (192.168.1.201): 56 data bytes\\n'
                    printf '64 bytes from 192.168.1.201: icmp_seq=0 ttl=64 time=1.23 ms\\n'
                    printf '64 bytes from 192.168.1.201: icmp_seq=1 ttl=64 time=1.18 ms\\n'
                    """
                ]
            }
        )
        let completionArrived = expectation(description: "completion")
        let recorder = RecordingLivePingOutput()

        _ = try pinger.ping(
            host: "192.168.1.201",
            onOutput: { text in
                recorder.outputs.append(text)
            },
            completion: { result in
                if case let .success(pingResult) = result {
                    recorder.results.append(pingResult)
                }
                completionArrived.fulfill()
            }
        )

        wait(for: [completionArrived], timeout: 2)
        let resultOutput = try XCTUnwrap(recorder.results.first?.output)
        XCTAssertTrue(resultOutput.contains("data bytes\n64 bytes from"), resultOutput)
        XCTAssertTrue(resultOutput.contains("icmp_seq=0 ttl=64 time=1.23 ms\n64 bytes from"), resultOutput)
        let liveOutput = recorder.outputs.joined()
        XCTAssertTrue(liveOutput.contains("PING 192.168.1.201"), liveOutput)
        XCTAssertTrue(liveOutput.contains("icmp_seq=0 ttl=64 time=1.23 ms"), liveOutput)
        XCTAssertTrue(liveOutput.contains("icmp_seq=1 ttl=64 time=1.18 ms"), liveOutput)
    }

    func testSystemPingRunnerDeliversRealPingOutputBeforeCompletion() throws {
        let pinger = SystemSessionSidebarHostPinger()
        let firstOutput = expectation(description: "real ping output")
        let completionArrived = expectation(description: "real ping completion")
        let recorder = RecordingLivePingOutput()
        let run = try pinger.ping(
            host: "192.168.1.201",
            onOutput: { text in
                recorder.outputs.append(text)
                if text.contains("PING") || text.contains("bytes from") {
                    firstOutput.fulfill()
                }
            },
            completion: { result in
                recorder.completed = true
                switch result {
                case let .success(pingResult):
                    recorder.results.append(pingResult)
                case let .failure(error):
                    recorder.errors.append(error)
                }
                completionArrived.fulfill()
            }
        )

        wait(for: [firstOutput], timeout: 2)
        XCTAssertFalse(recorder.completed)
        run.cancel()
        wait(for: [completionArrived], timeout: 2)
        XCTAssertFalse(recorder.outputs.joined().isEmpty)
    }

    func testSystemPingRunnerKeepsDefaultPingRunningUntilCancelled() throws {
        let pinger = SystemSessionSidebarHostPinger()
        let fifthReplyArrived = expectation(description: "fifth ping reply")
        let completionArrived = expectation(description: "completion after cancel")
        let recorder = RecordingLivePingOutput()
        var replyCount = 0
        var fulfilledFifthReply = false
        let run = try pinger.ping(
            host: "127.0.0.1",
            onOutput: { text in
                recorder.outputs.append(text)
                replyCount += text.components(separatedBy: "bytes from").count - 1
                if replyCount >= 5 && !fulfilledFifthReply {
                    fulfilledFifthReply = true
                    fifthReplyArrived.fulfill()
                }
            },
            completion: { result in
                recorder.completed = true
                switch result {
                case let .success(pingResult):
                    recorder.results.append(pingResult)
                case let .failure(error):
                    recorder.errors.append(error)
                }
                completionArrived.fulfill()
            }
        )

        wait(for: [fifthReplyArrived], timeout: 7)
        XCTAssertFalse(recorder.completed)
        run.cancel()
        wait(for: [completionArrived], timeout: 2)
        XCTAssertGreaterThanOrEqual(replyCount, 5)
    }

    func testPingProgressPanelUsesStacioSurfaceAndOutputContainer() throws {
        let presenter = AppKitSessionSidebarOperationsPresenter()
            .presentPingProgress(host: "192.168.1.201", parentWindow: nil)
        presenter.appendOutput("PING 192.168.1.201 (192.168.1.201): 56 data bytes\n")
        presenter.finish(
            SessionSidebarPingResult(
                host: "192.168.1.201",
                reachable: true,
                output: "64 bytes from 192.168.1.201\n"
            )
        )
        let panel = try XCTUnwrap(
            NSApp.windows.first { $0.accessibilityIdentifier() == "Stacio.Sidebar.pingProgressPanel" }
        )
        defer {
            panel.orderOut(nil)
        }
        let contentView = try XCTUnwrap(panel.contentView)
        let outputContainer = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Sidebar.pingProgressOutputContainer")
        )
        let outputTextView = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Sidebar.pingProgressOutput") as? NSTextView
        )
        let statusPill = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Sidebar.pingProgressStatus")
        )
        contentView.layoutSubtreeIfNeeded()

        XCTAssertEqual(outputContainer.layer?.borderWidth, 1)
        XCTAssertEqual(outputContainer.layer?.cornerRadius, 8)
        XCTAssertNotNil(outputContainer.layer?.backgroundColor)
        XCTAssertGreaterThan(outputTextView.frame.width, 0)
        XCTAssertGreaterThan(outputTextView.frame.height, 0)
        XCTAssertTrue(outputTextView.string.contains("PING 192.168.1.201"))
        XCTAssertEqual(statusPill.layer?.cornerRadius, 12)
    }

    func testPingProgressPanelPreservesLinuxStylePingRows() throws {
        let presenter = AppKitSessionSidebarOperationsPresenter()
            .presentPingProgress(host: "192.168.1.201", parentWindow: nil)
        presenter.appendOutput(
            """
            PING 192.168.1.201 (192.168.1.201): 56 data bytes
            64 bytes from 192.168.1.201: icmp_seq=0 ttl=64 time=1.23 ms
            64 bytes from 192.168.1.201: icmp_seq=1 ttl=64 time=1.18 ms

            """
        )
        let panel = try XCTUnwrap(
            NSApp.windows.first { $0.accessibilityIdentifier() == "Stacio.Sidebar.pingProgressPanel" }
        )
        defer {
            panel.orderOut(nil)
        }
        let contentView = try XCTUnwrap(panel.contentView)
        let outputTextView = try XCTUnwrap(
            contentView.firstSubview(withIdentifier: "Stacio.Sidebar.pingProgressOutput") as? NSTextView
        )
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(outputTextView.string.contains("data bytes\n64 bytes from"), outputTextView.string)
        XCTAssertTrue(outputTextView.string.contains("time=1.23 ms\n64 bytes from"), outputTextView.string)
        XCTAssertTrue(outputTextView.textContainer?.widthTracksTextView ?? false)
        XCTAssertFalse(outputTextView.isHorizontallyResizable)
    }

    func testPingProgressPanelIsModelessWhenParentWindowIsProvided() throws {
        let parentWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        parentWindow.animationBehavior = .none
        parentWindow.makeKeyAndOrderFront(nil)
        let presenter = AppKitSessionSidebarOperationsPresenter()
            .presentPingProgress(host: "192.168.1.201", parentWindow: parentWindow)
        presenter.appendOutput("PING 192.168.1.201 (192.168.1.201): 56 data bytes\n")
        presenter.finish(
            SessionSidebarPingResult(
                host: "192.168.1.201",
                reachable: true,
                output: "64 bytes from 192.168.1.201\n"
            )
        )

        let panel = try XCTUnwrap(
            NSApp.windows.first { $0.accessibilityIdentifier() == "Stacio.Sidebar.pingProgressPanel" }
        )
        defer {
            panel.orderOut(nil)
            parentWindow.orderOut(nil)
        }

        XCTAssertNil(parentWindow.attachedSheet)
        XCTAssertNil(panel.sheetParent)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(parentWindow.childWindows?.contains(panel) ?? false)

        let closeButton = try XCTUnwrap(
            panel.contentView?.firstSubview(withIdentifier: "Stacio.Sidebar.pingProgressAction") as? NSButton
        )
        closeButton.performClick(nil)
        XCTAssertFalse(parentWindow.childWindows?.contains(panel) ?? false)
        XCTAssertFalse(panel.isVisible)
    }

    func testSystemPingRunnerCancelInterruptsLongRunningProcess() throws {
        let pinger = SystemSessionSidebarHostPinger(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: { _ in
                [
                    "-c",
                    """
                    trap 'printf stopped\\\\n; exit 130' INT
                    trap '' TERM
                    printf started\\\\n
                    i=0
                    while [ $i -lt 40 ]; do
                      i=$((i + 1))
                      sleep 0.1
                    done
                    """
                ]
            }
        )
        let started = expectation(description: "process started")
        let completed = expectation(description: "process completed after cancel")
        let recorder = RecordingLivePingOutput()
        let run = try pinger.ping(
            host: "ignored.example.com",
            onOutput: { text in
                recorder.outputs.append(text)
                if text.contains("started") {
                    started.fulfill()
                }
            },
            completion: { result in
                recorder.completed = true
                switch result {
                case let .success(pingResult):
                    recorder.results.append(pingResult)
                case let .failure(error):
                    recorder.errors.append(error)
                }
                completed.fulfill()
            }
        )

        wait(for: [started], timeout: 1)
        run.cancel()
        wait(for: [completed], timeout: 1)

        XCTAssertTrue(recorder.completed)
        XCTAssertEqual(recorder.results.first?.reachable, false)
        XCTAssertTrue(recorder.outputs.joined().contains("stopped"))
    }

    func testContextMenuRenameUpdatesOnlySessionNameAndRefreshesOutline() {
        let original = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "Old API",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let updated = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "New API",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [original]],
            updatedSession: updated
        )
        let operations = RecordingSessionSidebarOperationsPresenter(renameValue: "New API")
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performContextMenuActionForTesting(.rename, id: "session_api")

        XCTAssertEqual(operations.renameRequestSessionIDs, ["session_api"])
        XCTAssertEqual(store.updatedRequests.map(\.id), ["session_api"])
        XCTAssertEqual(store.updatedRequests.map(\.update.name), ["New API"])
        XCTAssertEqual(store.updatedRequests.map(\.update.host), [nil])
        XCTAssertEqual(store.updatedRequests.map(\.update.port), [nil])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "New API\ndeploy@api.example.com:22")
    }

    func testContextMenuSaveSessionToFileWritesSingleSessionJSON() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: "cred_api",
            tags: ["prod"],
            lastOpenedAt: "2026-05-28T12:00:00Z"
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]],
            configJSONByID: [
                "session_api": ##"{"sessionIconID":"ubuntu","tagStyle":{"color":"#2266AA"},"startupCommand":"export TOKEN=hidden","environmentVariables":["PASSWORD=hidden"]}"##
            ]
        )
        let operations = RecordingSessionSidebarOperationsPresenter(singleSessionExportURL: destinationURL)
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performContextMenuActionForTesting(.saveToFile, id: "session_api")

        let data = try Data(contentsOf: destinationURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(object["format"] as? String, "stacio.sessions.v1")
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?["id"] as? String, "session_api")
        XCTAssertEqual(sessions.first?["host"] as? String, "api.example.com")
        XCTAssertEqual(
            sessions.first?["config_json"] as? String,
            #"{"sessionIconID":"ubuntu"}"#
        )
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("TOKEN") == true)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("PASSWORD") == true)
        XCTAssertEqual(operations.singleSessionExportRequestIDs, ["session_api"])
        XCTAssertEqual(operations.completedExportURLs, [destinationURL])
    }

    func testContextMenuCreateDesktopShortcutWritesShortcutFile() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("webloc")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let session = SessionRecord(
            id: "session api/1",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let operations = RecordingSessionSidebarOperationsPresenter(shortcutURL: destinationURL)
        let shortcutCreator = RecordingSessionSidebarShortcutCreator()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations,
            shortcutCreator: shortcutCreator
        )
        controller.loadView()

        controller.performContextMenuActionForTesting(.createDesktopShortcut, id: "session api/1")

        XCTAssertEqual(operations.shortcutRequestIDs, ["session api/1"])
        XCTAssertEqual(shortcutCreator.requests.map(\.session.id), ["session api/1"])
        XCTAssertEqual(shortcutCreator.requests.map(\.destinationURL), [destinationURL])
        XCTAssertEqual(operations.shortcutCreatedURLs, [destinationURL])
    }

    func testContextMenuSaveDefaultPresetStoresConfigAndCopySettingsWritesPasteboardText() throws {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: "cred_api",
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]],
            configJSONByID: [
                "session_api": ##"{"sessionIconID":"ubuntu","tagStyle":{"color":"#2266AA"},"postConnectScript":"curl https://secret.example"}"##
            ]
        )
        let operations = RecordingSessionSidebarOperationsPresenter()
        let presetStore = RecordingSessionSidebarDefaultPresetStore()
        let settingsCopier = RecordingSessionSidebarSettingsCopier()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations,
            defaultPresetStore: presetStore,
            settingsCopier: settingsCopier
        )
        controller.loadView()

        controller.performContextMenuActionForTesting(.saveAsDefaultPreset, id: "session_api")
        controller.performContextMenuActionForTesting(.copySettings, id: "session_api")

        XCTAssertEqual(presetStore.requests.map(\.session.id), ["session_api"])
        XCTAssertEqual(
            presetStore.requests.map(\.configJSON),
            [##"{"sessionIconID":"ubuntu","tagStyle":{"color":"#2266AA"},"postConnectScript":"curl https://secret.example"}"##]
        )
        XCTAssertEqual(operations.defaultPresetSavedSessionIDs, ["session_api"])
        XCTAssertEqual(settingsCopier.texts.count, 1)
        XCTAssertTrue(settingsCopier.texts[0].contains(#""format" : "stacio.sessions.v1""#))
        XCTAssertTrue(settingsCopier.texts[0].contains(#""API Server""#))
        XCTAssertTrue(settingsCopier.texts[0].contains(#"\"sessionIconID\":\"ubuntu\""#))
        XCTAssertFalse(settingsCopier.texts[0].contains("postConnectScript"))
        XCTAssertFalse(settingsCopier.texts[0].contains("secret.example"))
        XCTAssertEqual(operations.settingsCopiedCount, 1)
    }

    func testAddSessionUsesEditorStoreAndRefreshesOutline() {
        let draft = SessionDraft(
            folderId: nil,
            name: "New API",
            protocol: "ssh",
            host: "new-api.example.com",
            port: 2200,
            username: "ops",
            privateKeyPath: "~/.ssh/ops",
            credentialId: nil,
            tags: ["new"],
            configJson: nil
        )
        let created = SessionRecord(
            id: "session_new_api",
            folderId: nil,
            name: "New API",
            protocol: "ssh",
            host: "new-api.example.com",
            port: 2200,
            username: "ops",
            privateKeyPath: "~/.ssh/ops",
            credentialId: nil,
            tags: ["new"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [:],
            createdSession: created
        )
        let editor = RecordingSessionEditor(draft: draft)
        let controller = SessionSidebarViewController(sessionStore: store, sessionEditor: editor)
        controller.loadView()

        controller.performAddSessionForTesting()

        XCTAssertEqual(editor.requests, ["new:nil"])
        XCTAssertEqual(store.createdDrafts, [draft])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "New API\nops@new-api.example.com:2200")
    }

    func testAddSessionPresentsStoreCreateError() {
        let draft = SessionDraft(
            folderId: nil,
            name: "New API",
            protocol: "ssh",
            host: "new-api.example.com",
            port: 2200,
            username: "ops",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            configJson: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [:],
            createError: TestSessionSidebarError.failed
        )
        let editor = RecordingSessionEditor(draft: draft)
        let errorPresenter = RecordingSessionSidebarErrorPresenter()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            sessionEditor: editor,
            errorPresenter: errorPresenter
        )
        controller.loadView()

        controller.performAddSessionForTesting()

        XCTAssertEqual(errorPresenter.contexts, [.createSession])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "")
    }

    func testEditSessionUsesEditorStoreAndRefreshesOutline() {
        let original = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "Old API",
            protocol: "ssh",
            host: "old-api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["old"],
            lastOpenedAt: nil
        )
        let updated = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.internal",
            port: 2222,
            username: "ops",
            privateKeyPath: "~/.ssh/prod",
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let draft = SessionDraft(
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.internal",
            port: 2222,
            username: "ops",
            privateKeyPath: "~/.ssh/prod",
            credentialId: nil,
            tags: ["prod"],
            configJson: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [original]],
            updatedSession: updated
        )
        let editor = RecordingSessionEditor(draft: draft)
        let controller = SessionSidebarViewController(sessionStore: store, sessionEditor: editor)
        controller.loadView()

        controller.performEditSessionForTesting(id: "session_api")

        XCTAssertEqual(editor.requests, ["edit:session_api"])
        XCTAssertEqual(store.updatedRequests.map(\.id), ["session_api"])
        XCTAssertEqual(store.updatedRequests.map(\.update.name), ["API Server"])
        XCTAssertEqual(store.updatedRequests.map(\.update.host), ["api.internal"])
        XCTAssertEqual(store.updatedRequests.map(\.update.port), [2222])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "API Server\nops@api.internal:2222")
    }

    func testEditSessionRequestsCredentialCleanupAfterSuccessfulUpdate() {
        let original = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "Old API",
            protocol: "ssh",
            host: "old-api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: "cred_old",
            tags: ["old"],
            lastOpenedAt: nil
        )
        let draft = SessionDraft(
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.internal",
            port: 2222,
            username: "ops",
            privateKeyPath: nil,
            credentialId: "cred_new",
            tags: ["prod"],
            configJson: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [original]]
        )
        let editor = RecordingSessionEditor(draft: draft)
        let cleaner = RecordingSessionCredentialCleaner()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            sessionEditor: editor,
            credentialCleaner: cleaner
        )
        controller.loadView()

        controller.performEditSessionForTesting(id: "session_api")

        XCTAssertEqual(cleaner.requests.map(\.previousCredentialID), ["cred_old"])
        XCTAssertEqual(cleaner.requests.map(\.replacementCredentialID), ["cred_new"])
    }

    func testEditSessionPresentsStoreUpdateError() {
        let original = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "Old API",
            protocol: "ssh",
            host: "old-api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["old"],
            lastOpenedAt: nil
        )
        let draft = SessionDraft(
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.internal",
            port: 2222,
            username: "ops",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            configJson: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [original]],
            updateError: TestSessionSidebarError.failed
        )
        let editor = RecordingSessionEditor(draft: draft)
        let errorPresenter = RecordingSessionSidebarErrorPresenter()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            sessionEditor: editor,
            errorPresenter: errorPresenter
        )
        controller.loadView()

        controller.performEditSessionForTesting(id: "session_api")

        XCTAssertEqual(errorPresenter.contexts, [.updateSession])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "Old API\ndeploy@old-api.example.com:22")
    }

    func testEditSessionSendsBlankOptionalFieldsWhenUserClearsThem() {
        let original = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let draft = SessionDraft(
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: nil,
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            configJson: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [original]]
        )
        let editor = RecordingSessionEditor(draft: draft)
        let controller = SessionSidebarViewController(sessionStore: store, sessionEditor: editor)
        controller.loadView()

        controller.performEditSessionForTesting(id: "session_api")

        XCTAssertEqual(store.updatedRequests.map(\.update.username), [""])
        XCTAssertEqual(store.updatedRequests.map(\.update.privateKeyPath), [""])
    }

    func testDuplicateSessionUsesStoreAndRefreshesOutline() {
        let original = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: "2026-05-28T12:00:00Z"
        )
        let duplicated = SessionRecord(
            id: "session_api_copy",
            folderId: nil,
            name: "API Server 副本",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "~/.ssh/prod",
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [original]],
            duplicatedSession: duplicated
        )
        let controller = SessionSidebarViewController(sessionStore: store)
        controller.loadView()

        controller.performDuplicateSessionForTesting(id: "session_api")

        XCTAssertEqual(store.duplicatedRequests.map(\.id), ["session_api"])
        XCTAssertEqual(store.duplicatedRequests.map(\.targetFolderID), [nil])
        XCTAssertEqual(
            controller.sessionOutlineTextSnapshot,
            "API Server\ndeploy@api.example.com:22\nAPI Server 副本\ndeploy@api.example.com:22"
        )
    }

    func testMoveSessionUsesPresenterDestinationAndRefreshesOutline() {
        let production = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let original = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let moved = SessionRecord(
            id: "session_api",
            folderId: production.id,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [production],
            sessionsByFolderID: [nil: [original], production.id: []],
            movedSession: moved
        )
        let operations = RecordingSessionSidebarOperationsPresenter(
            moveDestination: SessionSidebarMoveDestination(folderID: production.id)
        )
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performContextMenuActionForTesting(.move, id: "session_api")

        XCTAssertEqual(operations.moveRequestSessionIDs, ["session_api"])
        XCTAssertEqual(store.movedRequests.map(\.id), ["session_api"])
        XCTAssertEqual(store.movedRequests.map(\.targetFolderID), [production.id])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "Production\nAPI Server\ndeploy@api.example.com:22")
    }

    func testMoveSessionCancelDoesNotUpdateStore() {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let operations = RecordingSessionSidebarOperationsPresenter(moveDestination: nil)
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performMoveSessionForTesting(id: "session_api")

        XCTAssertEqual(store.movedRequests.count, 0)
    }

    func testMoveSessionToCurrentFolderDoesNotReorderStore() {
        let session = makeSession(id: "api", protocolName: "ssh", name: "API Server")
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let operations = RecordingSessionSidebarOperationsPresenter(
            moveDestination: SessionSidebarMoveDestination(folderID: nil)
        )
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performMoveSessionForTesting(id: session.id)

        XCTAssertEqual(operations.moveRequestSessionIDs, [session.id])
        XCTAssertTrue(store.movedRequests.isEmpty)
    }

    func testExportSessionsWritesJSONToPresenterDestination() throws {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let store = RecordingSessionSidebarStore(
            folders: [],
            exportJSON: #"{"format":"stacio.sessions.v1","sessions":[]}"#
        )
        let operations = RecordingSessionSidebarOperationsPresenter(exportURL: destinationURL)
        let controller = SessionSidebarViewController(
            sessionStore: store,
            operationsPresenter: operations
        )
        controller.loadView()

        controller.performExportSessionsForTesting()

        XCTAssertEqual(store.exportCount, 1)
        XCTAssertEqual(operations.exportSuggestedNames, ["Stacio Sessions.json"])
        XCTAssertEqual(
            try String(contentsOf: destinationURL, encoding: .utf8),
            #"{"format":"stacio.sessions.v1","sessions":[]}"#
        )
    }

    func testDeleteSessionConfirmsDeletesAndRefreshesOutline() {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let confirmer = RecordingSessionDeleteConfirmer(shouldDelete: true)
        let controller = SessionSidebarViewController(
            sessionStore: store,
            sessionDeleteConfirmer: confirmer
        )
        controller.loadView()

        controller.performDeleteSessionForTesting(id: "session_api")

        XCTAssertEqual(confirmer.requestedIDs, ["session_api"])
        XCTAssertEqual(store.deletedIDs, ["session_api"])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "")
    }

    func testDeleteSessionClearsRemoteEditCacheAfterDeletingRecord() {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let cacheCleaner = RecordingRemoteEditSessionCacheCleaner()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            sessionDeleteConfirmer: RecordingSessionDeleteConfirmer(shouldDelete: true),
            remoteEditCacheCleaner: cacheCleaner
        )
        controller.loadView()

        controller.performDeleteSessionForTesting(id: "session_api")

        XCTAssertEqual(store.events.filter { $0.hasPrefix("delete:") }, ["delete:session_api"])
        XCTAssertEqual(cacheCleaner.clearedSessionIDs, ["session_api"])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "")
    }

    func testDeleteSessionKeepsRecordDeletionWhenRemoteEditCacheClearFails() {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let cacheCleaner = RecordingRemoteEditSessionCacheCleaner(error: TestSessionSidebarError.failed)
        let errorPresenter = RecordingSessionSidebarErrorPresenter()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            sessionDeleteConfirmer: RecordingSessionDeleteConfirmer(shouldDelete: true),
            errorPresenter: errorPresenter,
            remoteEditCacheCleaner: cacheCleaner
        )
        controller.loadView()

        controller.performDeleteSessionForTesting(id: "session_api")

        XCTAssertEqual(store.deletedIDs, ["session_api"])
        XCTAssertEqual(cacheCleaner.clearedSessionIDs, ["session_api"])
        XCTAssertEqual(errorPresenter.contexts, [])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "")
    }

    func testDeleteSessionPresentsStoreDeleteError() {
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API Server",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: nil,
            tags: ["prod"],
            lastOpenedAt: nil
        )
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]],
            deleteError: TestSessionSidebarError.failed
        )
        let confirmer = RecordingSessionDeleteConfirmer(shouldDelete: true)
        let errorPresenter = RecordingSessionSidebarErrorPresenter()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            sessionDeleteConfirmer: confirmer,
            errorPresenter: errorPresenter
        )
        controller.loadView()

        controller.performDeleteSessionForTesting(id: "session_api")

        XCTAssertEqual(errorPresenter.contexts, [.deleteSession])
        XCTAssertEqual(controller.sessionOutlineTextSnapshot, "API Server\ndeploy@api.example.com:22")
    }

    func testFolderContextMenuIsBuiltFromTheRightClickedOutlineRow() {
        let folder = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(folders: [folder])
        )
        controller.loadView()

        XCTAssertEqual(
            controller.contextMenuTitlesForTesting(row: 0),
            ["新建分组", "重命名分组", "删除分组", "导出分组会话"]
        )
    }

    func testSidebarMovesSessionIntoFolderAtRequestedMixedSiblingIndex() {
        let folder = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let root = makeSession(id: "root", protocolName: "ssh", name: "Root")
        let existing = makeSession(
            id: "existing",
            protocolName: "ssh",
            name: "Existing",
            folderID: folder.id
        )
        let store = RecordingSessionSidebarStore(
            folders: [folder],
            sessionsByFolderID: [nil: [root], folder.id: [existing]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)
        controller.loadView()

        XCTAssertTrue(
            controller.performSidebarDropForTesting(
                kind: "session",
                id: root.id,
                targetFolderID: folder.id,
                targetIndex: 0
            )
        )

        XCTAssertEqual(store.placedSidebarRequests.map(\.kind), ["session"])
        XCTAssertEqual(store.placedSidebarRequests.map(\.targetFolderID), [folder.id])
        XCTAssertEqual(store.placedSidebarRequests.map(\.targetIndex), [0])
        XCTAssertEqual(
            controller.sessionOutlineTextSnapshot,
            "Production\nRoot\nops@root.example.com:22\nExisting\nops@existing.example.com:22"
        )
        XCTAssertTrue(controller.isFolderExpandedForTesting(folderID: folder.id))
    }

    func testSidebarMovesSessionOutOfFolderAndKeepsTheNewOrderAcrossReload() {
        let folder = SessionFolder(id: "folder_prod", parentId: nil, name: "Production")
        let root = makeSession(id: "root", protocolName: "ssh", name: "Root")
        let nested = makeSession(
            id: "nested",
            protocolName: "ssh",
            name: "Nested",
            folderID: folder.id
        )
        let store = RecordingSessionSidebarStore(
            folders: [folder],
            sessionsByFolderID: [nil: [root], folder.id: [nested]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)
        controller.loadView()

        XCTAssertTrue(
            controller.performSidebarDropForTesting(
                kind: "session",
                id: nested.id,
                targetFolderID: nil,
                targetIndex: 0
            )
        )
        controller.reloadSessions()

        XCTAssertEqual(
            controller.sessionOutlineTextSnapshot,
            "Nested\nops@nested.example.com:22\nRoot\nops@root.example.com:22\nProduction"
        )
    }

    func testSidebarReordersFoldersAndSessionsInOneSiblingSequence() {
        let firstFolder = SessionFolder(id: "folder_first", parentId: nil, name: "First Folder")
        let secondFolder = SessionFolder(id: "folder_second", parentId: nil, name: "Second Folder")
        let session = makeSession(id: "root", protocolName: "ssh", name: "Root")
        let store = RecordingSessionSidebarStore(
            folders: [firstFolder, secondFolder],
            sessionsByFolderID: [nil: [session]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)
        controller.loadView()

        XCTAssertTrue(
            controller.performSidebarDropForTesting(
                kind: "folder",
                id: secondFolder.id,
                targetFolderID: nil,
                targetIndex: 0
            )
        )

        XCTAssertEqual(
            controller.sessionOutlineTextSnapshot,
            "Second Folder\nRoot\nops@root.example.com:22\nFirst Folder"
        )
    }

    func testDropOnPersistedSessionRowRetargetsToBeforeOrAfterTheRow() throws {
        let source = makeSession(id: "source", protocolName: "ssh", name: "Source")
        let target = makeSession(id: "target", protocolName: "ssh", name: "Target")
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(
                folders: [],
                sessionsByFolderID: [nil: [source, target]]
            )
        )
        controller.loadView()

        let before = try XCTUnwrap(
            controller.resolvedSidebarDropOnItemForTesting(
                kind: "session",
                id: source.id,
                targetKind: "session",
                targetID: target.id,
                insertAfter: false
            )
        )
        let after = try XCTUnwrap(
            controller.resolvedSidebarDropOnItemForTesting(
                kind: "session",
                id: source.id,
                targetKind: "session",
                targetID: target.id,
                insertAfter: true
            )
        )

        XCTAssertNil(before.targetFolderID)
        XCTAssertEqual(before.targetIndex, 0)
        XCTAssertNil(after.targetFolderID)
        XCTAssertEqual(after.targetIndex, 1)
    }

    func testDropOnPersistedSessionRowRetargetsFolderWithinTheSameParent() throws {
        let folder = SessionFolder(id: "folder_source", parentId: nil, name: "Source Folder")
        let target = makeSession(id: "target", protocolName: "ssh", name: "Target")
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(
                folders: [folder],
                sessionsByFolderID: [nil: [target]]
            )
        )
        controller.loadView()

        let before = try XCTUnwrap(
            controller.resolvedSidebarDropOnItemForTesting(
                kind: "folder",
                id: folder.id,
                targetKind: "session",
                targetID: target.id,
                insertAfter: false
            )
        )
        let after = try XCTUnwrap(
            controller.resolvedSidebarDropOnItemForTesting(
                kind: "folder",
                id: folder.id,
                targetKind: "session",
                targetID: target.id,
                insertAfter: true
            )
        )

        XCTAssertNil(before.targetFolderID)
        XCTAssertEqual(before.targetIndex, 0)
        XCTAssertNil(after.targetFolderID)
        XCTAssertEqual(after.targetIndex, 1)
    }

    func testVirtualGroupsDoNotShiftRootDropIndexAndCannotBeDragged() throws {
        let favorite = makeSession(
            id: "favorite",
            protocolName: "ssh",
            name: "Favorite",
            tags: ["favorite"]
        )
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(
                folders: [],
                sessionsByFolderID: [nil: [favorite]]
            )
        )
        controller.loadView()

        let virtualFolder = controller.outlineView(controller.outlineView, child: 0, ofItem: nil)
        let virtualSession = controller.outlineView(controller.outlineView, child: 0, ofItem: virtualFolder)
        let persistedSession = controller.outlineView(controller.outlineView, child: 1, ofItem: nil)
        let proposal = try XCTUnwrap(
            controller.resolvedSidebarDropForTesting(
                kind: "session",
                id: favorite.id,
                proposedFolderID: nil,
                childIndex: 1
            )
        )

        XCTAssertNil(controller.outlineView(controller.outlineView, pasteboardWriterForItem: virtualSession))
        XCTAssertNotNil(controller.outlineView(controller.outlineView, pasteboardWriterForItem: persistedSession))
        XCTAssertNil(proposal.targetFolderID)
        XCTAssertEqual(proposal.targetIndex, 0)
    }

    func testSidebarDisablesReorderingWhileSearchIsFilteringTheTree() throws {
        let session = makeSession(id: "root", protocolName: "ssh", name: "Root")
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]]
        )
        let controller = SessionSidebarViewController(sessionStore: store)
        controller.loadView()
        try controller.performSearchForTesting("Root")

        XCTAssertFalse(
            controller.performSidebarDropForTesting(
                kind: "session",
                id: session.id,
                targetFolderID: nil,
                targetIndex: 0
            )
        )
        XCTAssertTrue(store.placedSidebarRequests.isEmpty)
    }

    func testSidebarKeepsCurrentTreeWhenPersistedDropFails() {
        let session = makeSession(id: "root", protocolName: "ssh", name: "Root")
        let store = RecordingSessionSidebarStore(
            folders: [],
            sessionsByFolderID: [nil: [session]],
            placeError: TestSessionSidebarError.failed
        )
        let errorPresenter = RecordingSessionSidebarErrorPresenter()
        let controller = SessionSidebarViewController(
            sessionStore: store,
            errorPresenter: errorPresenter
        )
        controller.loadView()
        let before = controller.sessionOutlineTextSnapshot

        XCTAssertFalse(
            controller.performSidebarDropForTesting(
                kind: "session",
                id: session.id,
                targetFolderID: nil,
                targetIndex: 0
            )
        )

        XCTAssertEqual(controller.sessionOutlineTextSnapshot, before)
        XCTAssertEqual(errorPresenter.contexts, [.moveSession])
    }

    func testExpandAndCollapseAllGroupsPersistAcrossReload() {
        let root = SessionFolder(id: "folder_root", parentId: nil, name: "Root")
        let child = SessionFolder(id: "folder_child", parentId: root.id, name: "Child")
        let grandchild = SessionFolder(id: "folder_grandchild", parentId: child.id, name: "Grandchild")
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(folders: [root, child, grandchild])
        )
        controller.loadView()

        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.expandAllGroups"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.collapseAllGroups"))
        XCTAssertTrue(controller.isFolderExpandedForTesting(folderID: root.id))
        XCTAssertTrue(controller.isFolderExpandedForTesting(folderID: child.id))

        controller.performCollapseAllFoldersForTesting()
        controller.reloadSessions()

        XCTAssertFalse(controller.isFolderExpandedForTesting(folderID: root.id))
        XCTAssertFalse(controller.isFolderExpandedForTesting(folderID: child.id))

        controller.performExpandAllFoldersForTesting()

        XCTAssertTrue(controller.isFolderExpandedForTesting(folderID: root.id))
        XCTAssertTrue(controller.isFolderExpandedForTesting(folderID: child.id))
        XCTAssertTrue(controller.isFolderExpandedForTesting(folderID: grandchild.id))
    }

    func testSearchDisablesExpansionControlsAndRestoresThePreviousExpansionState() throws {
        let root = SessionFolder(id: "folder_root", parentId: nil, name: "Root")
        let child = SessionFolder(id: "folder_child", parentId: root.id, name: "Matching Child")
        let controller = SessionSidebarViewController(
            sessionStore: RecordingSessionSidebarStore(folders: [root, child])
        )
        controller.loadView()
        let expandButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.expandAllGroups") as? NSButton
        )
        let collapseButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Sidebar.collapseAllGroups") as? NSButton
        )
        controller.performCollapseAllFoldersForTesting()

        try controller.performSearchForTesting("Matching")

        XCTAssertFalse(expandButton.isEnabled)
        XCTAssertFalse(collapseButton.isEnabled)
        XCTAssertTrue(controller.isFolderExpandedForTesting(folderID: root.id))

        try controller.performSearchForTesting("")

        XCTAssertTrue(expandButton.isEnabled)
        XCTAssertTrue(collapseButton.isEnabled)
        XCTAssertFalse(controller.isFolderExpandedForTesting(folderID: root.id))
        XCTAssertFalse(controller.isFolderExpandedForTesting(folderID: child.id))
    }
}

private extension SessionSidebarViewController {
    func performSearchForTesting(_ query: String) throws {
        let searchField = try XCTUnwrap(
            view.firstSubview(withIdentifier: "Stacio.Sidebar.search") as? NSSearchField
        )
        searchField.stringValue = query
        searchField.sendAction(searchField.action, to: searchField.target)
    }
}

private func makeSession(
    id: String,
    protocolName: String,
    name: String,
    folderID: String? = nil,
    tags: [String] = []
) -> SessionRecord {
    SessionRecord(
        id: "session_\(id)",
        folderId: folderID,
        name: name,
        protocol: protocolName,
        host: "\(id).example.com",
        port: 22,
        username: "ops",
        privateKeyPath: nil,
        credentialId: nil,
        tags: tags,
        lastOpenedAt: nil
    )
}

private final class RecordingSessionSidebarStore: SessionSidebarStoring {
    var events: [String] = []
    var createdDrafts: [SessionDraft] = []
    var updatedRequests: [(id: String, update: SessionUpdate)] = []
    var duplicatedRequests: [(id: String, targetFolderID: String?)] = []
    var movedRequests: [(id: String, targetFolderID: String?)] = []
    var placedSidebarRequests: [(kind: String, id: String, targetFolderID: String?, targetIndex: UInt32)] = []
    var createdFolderRequests: [(parentID: String?, name: String)] = []
    var renamedFolderRequests: [(id: String, name: String)] = []
    var deletedFolderIDs: [String] = []
    var exportedFolderIDs: [String] = []
    var deletedIDs: [String] = []
    var exportCount = 0
    private var folders: [SessionFolder]
    private var sessionsByFolderID: Dictionary<String?, [SessionRecord]>
    private var sidebarOrderByParentID: Dictionary<String?, [(kind: String, id: String)]> = [:]
    private let createdSession: SessionRecord?
    private let updatedSession: SessionRecord?
    private let duplicatedSession: SessionRecord?
    private let movedSession: SessionRecord?
    private let exportJSON: String
    private let folderExportJSON: String
    private let configJSONByID: [String: String]
    private let createError: Error?
    private let updateError: Error?
    private let deleteError: Error?
    private let placeError: Error?

    init(
        folders: [SessionFolder],
        sessionsByFolderID: Dictionary<String?, [SessionRecord]> = [:],
        createdSession: SessionRecord? = nil,
        updatedSession: SessionRecord? = nil,
        duplicatedSession: SessionRecord? = nil,
        movedSession: SessionRecord? = nil,
        exportJSON: String = "{}",
        folderExportJSON: String = "{}",
        configJSONByID: [String: String] = [:],
        createError: Error? = nil,
        updateError: Error? = nil,
        deleteError: Error? = nil,
        placeError: Error? = nil
    ) {
        self.folders = folders
        self.sessionsByFolderID = sessionsByFolderID
        self.createdSession = createdSession
        self.updatedSession = updatedSession
        self.duplicatedSession = duplicatedSession
        self.movedSession = movedSession
        self.exportJSON = exportJSON
        self.folderExportJSON = folderExportJSON
        self.configJSONByID = configJSONByID
        self.createError = createError
        self.updateError = updateError
        self.deleteError = deleteError
        self.placeError = placeError
        rebuildSidebarOrder()
    }

    func listFolders() throws -> [SessionFolder] {
        events.append("folders")
        return folders
    }

    func listSidebarOrder() throws -> [SessionSidebarOrderItem] {
        sidebarOrderByParentID.flatMap { parentID, items in
            items.map { item in
                SessionSidebarOrderItem(kind: item.kind, id: item.id, parentId: parentID)
            }
        }
    }

    func createFolder(parentID: String?, name: String) throws -> SessionFolder {
        events.append("createFolder:\(parentID ?? "nil"):\(name)")
        createdFolderRequests.append((parentID: parentID, name: name))
        let folder = SessionFolder(
            id: "folder_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))",
            parentId: parentID,
            name: name
        )
        folders.append(folder)
        sidebarOrderByParentID[parentID, default: []].append((kind: "folder", id: folder.id))
        return folder
    }

    func renameFolder(id: String, name: String) throws -> SessionFolder {
        events.append("renameFolder:\(id):\(name)")
        renamedFolderRequests.append((id: id, name: name))
        let renamed = SessionFolder(
            id: id,
            parentId: folders.first(where: { $0.id == id })?.parentId,
            name: name
        )
        folders = folders.map { $0.id == id ? renamed : $0 }
        return renamed
    }

    func deleteFolder(id: String) throws {
        events.append("deleteFolder:\(id)")
        deletedFolderIDs.append(id)
        folders.removeAll { $0.id == id || $0.parentId == id }
        sidebarOrderByParentID = sidebarOrderByParentID.mapValues { items in
            items.filter { $0.kind != "folder" || $0.id != id }
        }
    }

    func listSessions(folderID: String?) throws -> [SessionRecord] {
        events.append("sessions:\(folderID ?? "nil")")
        return sessionsByFolderID[folderID] ?? []
    }

    func loadSnapshot() throws -> SessionSidebarSnapshot {
        events.append("snapshot")
        let sessions = sessionsByFolderID.values.flatMap { $0 }
        let orderItems = sidebarOrderByParentID.flatMap { parentID, items in
            items.map { item in
                SessionSidebarOrderItem(kind: item.kind, id: item.id, parentId: parentID)
            }
        }
        let sessionIDs = Set(sessions.map(\.id))
        let iconAssignments = configJSONByID.compactMap { sessionID, configJSON -> SessionIconAssignment? in
            guard sessionIDs.contains(sessionID),
                  let data = configJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let iconID = (object["sessionIconID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !iconID.isEmpty,
                  iconID.count <= 64,
                  iconID.utf8.allSatisfy({ byte in
                      (48...57).contains(byte)
                          || (65...90).contains(byte)
                          || (97...122).contains(byte)
                          || byte == 45
                          || byte == 95
                  })
            else {
                return nil
            }
            return SessionIconAssignment(sessionId: sessionID, iconId: iconID)
        }
        return SessionSidebarSnapshot(
            folders: folders,
            sessions: sessions,
            orderItems: orderItems,
            manualIconAssignments: iconAssignments
        )
    }

    func createSession(_ draft: SessionDraft) throws -> SessionRecord {
        if let createError {
            throw createError
        }
        events.append("create:\(draft.name)")
        createdDrafts.append(draft)
        let session = createdSession ?? SessionRecord(
            id: "session_created",
            folderId: draft.folderId,
            name: draft.name,
            protocol: draft.protocol,
            host: draft.host,
            port: draft.port,
            username: draft.username,
            privateKeyPath: draft.privateKeyPath,
            credentialId: draft.credentialId,
            tags: draft.tags,
            lastOpenedAt: nil
        )
        sessionsByFolderID[draft.folderId, default: []].append(session)
        sidebarOrderByParentID[draft.folderId, default: []].append((kind: "session", id: session.id))
        return session
    }

    func updateSession(id: String, update: SessionUpdate) throws -> SessionRecord {
        if let updateError {
            throw updateError
        }
        events.append("update:\(id)")
        updatedRequests.append((id: id, update: update))
        let previous = sessionsByFolderID.values.flatMap { $0 }.first { $0.id == id }
        let session = updatedSession ?? SessionRecord(
            id: id,
            folderId: update.folderId,
            name: update.name ?? "Updated",
            protocol: "ssh",
            host: update.host ?? "updated.example.com",
            port: update.port ?? 22,
            username: update.username,
            privateKeyPath: update.privateKeyPath,
            credentialId: update.credentialId,
            tags: update.tags ?? [],
            lastOpenedAt: nil
        )
        if previous?.folderId != session.folderId {
            sessionsByFolderID = sessionsByFolderID.mapValues { sessions in
                sessions.filter { $0.id != id }
            }
            sessionsByFolderID[session.folderId, default: []].append(session)
            removeSidebarOrderItem(kind: "session", id: id)
            sidebarOrderByParentID[session.folderId, default: []].append((kind: "session", id: id))
        } else {
            sessionsByFolderID = sessionsByFolderID.mapValues { sessions in
                sessions.map { $0.id == id ? session : $0 }
            }
        }
        return session
    }

    func duplicateSession(id: String, targetFolderID: String?) throws -> SessionRecord {
        events.append("duplicate:\(id)")
        duplicatedRequests.append((id: id, targetFolderID: targetFolderID))
        let source = sessionsByFolderID.values.flatMap { $0 }.first { $0.id == id }
        let session = duplicatedSession ?? SessionRecord(
            id: "\(id)_copy",
            folderId: targetFolderID,
            name: "\(source?.name ?? "Session") 副本",
            protocol: source?.protocol ?? "ssh",
            host: source?.host ?? "copy.example.com",
            port: source?.port ?? 22,
            username: source?.username,
            privateKeyPath: source?.privateKeyPath,
            credentialId: source?.credentialId,
            tags: source?.tags ?? [],
            lastOpenedAt: nil
        )
        sessionsByFolderID[targetFolderID, default: []].append(session)
        sidebarOrderByParentID[targetFolderID, default: []].append((kind: "session", id: session.id))
        return session
    }

    func moveSession(id: String, targetFolderID: String?) throws -> SessionRecord {
        events.append("move:\(id)")
        movedRequests.append((id: id, targetFolderID: targetFolderID))
        let source = sessionsByFolderID.values.flatMap { $0 }.first { $0.id == id }
        let session = movedSession ?? SessionRecord(
            id: id,
            folderId: targetFolderID,
            name: source?.name ?? "Moved",
            protocol: source?.protocol ?? "ssh",
            host: source?.host ?? "moved.example.com",
            port: source?.port ?? 22,
            username: source?.username,
            privateKeyPath: source?.privateKeyPath,
            credentialId: source?.credentialId,
            tags: source?.tags ?? [],
            lastOpenedAt: source?.lastOpenedAt
        )
        sessionsByFolderID = sessionsByFolderID.mapValues { sessions in
            sessions.filter { $0.id != id }
        }
        sessionsByFolderID[targetFolderID, default: []].append(session)
        removeSidebarOrderItem(kind: "session", id: id)
        sidebarOrderByParentID[targetFolderID, default: []].append((kind: "session", id: session.id))
        return session
    }

    func placeSidebarItem(
        kind: String,
        id: String,
        targetFolderID: String?,
        targetIndex: UInt32
    ) throws {
        if let placeError {
            throw placeError
        }
        placedSidebarRequests.append((
            kind: kind,
            id: id,
            targetFolderID: targetFolderID,
            targetIndex: targetIndex
        ))
        removeSidebarOrderItem(kind: kind, id: id)
        var targetItems = sidebarOrderByParentID[targetFolderID] ?? []
        let insertionIndex = min(Int(targetIndex), targetItems.count)
        targetItems.insert((kind: kind, id: id), at: insertionIndex)
        sidebarOrderByParentID[targetFolderID] = targetItems

        guard kind == "session",
              let source = sessionsByFolderID.values.flatMap({ $0 }).first(where: { $0.id == id })
        else {
            return
        }
        let moved = SessionRecord(
            id: source.id,
            folderId: targetFolderID,
            name: source.name,
            protocol: source.protocol,
            host: source.host,
            port: source.port,
            username: source.username,
            privateKeyPath: source.privateKeyPath,
            credentialId: source.credentialId,
            tags: source.tags,
            lastOpenedAt: source.lastOpenedAt
        )
        sessionsByFolderID = sessionsByFolderID.mapValues { sessions in
            sessions.filter { $0.id != id }
        }
        sessionsByFolderID[targetFolderID, default: []].append(moved)
    }

    func exportSessionsJSON() throws -> String {
        events.append("export")
        exportCount += 1
        return exportJSON
    }

    func exportSessionFolderJSON(folderID: String) throws -> String {
        events.append("exportFolder:\(folderID)")
        exportedFolderIDs.append(folderID)
        return folderExportJSON
    }

    func getSessionConfigJSON(id: String) throws -> String? {
        events.append("config:\(id)")
        return configJSONByID[id]
    }

    func deleteSession(id: String) throws {
        if let deleteError {
            throw deleteError
        }
        events.append("delete:\(id)")
        deletedIDs.append(id)
        sessionsByFolderID = sessionsByFolderID.mapValues { sessions in
            sessions.filter { $0.id != id }
        }
        removeSidebarOrderItem(kind: "session", id: id)
    }

    private func rebuildSidebarOrder() {
        sidebarOrderByParentID = [:]
        let rootSessions = sessionsByFolderID[nil] ?? []
        sidebarOrderByParentID[nil] = rootSessions.map { (kind: "session", id: $0.id) }
            + folders.filter { $0.parentId == nil }.map { (kind: "folder", id: $0.id) }
        for folder in folders {
            let childFolders = folders.filter { $0.parentId == folder.id }
            let sessions = sessionsByFolderID[folder.id] ?? []
            sidebarOrderByParentID[folder.id] = childFolders.map { (kind: "folder", id: $0.id) }
                + sessions.map { (kind: "session", id: $0.id) }
        }
    }

    private func removeSidebarOrderItem(kind: String, id: String) {
        sidebarOrderByParentID = sidebarOrderByParentID.mapValues { items in
            items.filter { $0.kind != kind || $0.id != id }
        }
    }
}

private enum TestSessionSidebarError: Error {
    case failed
}

private final class RecordingRemoteEditSessionCacheCleaner: RemoteEditSessionCacheClearing {
    var clearedSessionIDs: [String] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func clearSession(sessionID: String) throws {
        clearedSessionIDs.append(sessionID)
        if let error {
            throw error
        }
    }
}

private final class RecordingSessionEditor: SessionSidebarSessionEditing {
    var requests: [String] = []
    private let draft: SessionDraft?

    init(draft: SessionDraft?) {
        self.draft = draft
    }

    func makeSessionDraft(
        existingSession: SessionRecord?,
        selectedFolderID: String?,
        parentWindow: NSWindow?
    ) -> SessionDraft? {
        if let existingSession {
            requests.append("edit:\(existingSession.id)")
        } else {
            requests.append("new:\(selectedFolderID ?? "nil")")
        }
        return draft
    }
}

private final class RecordingSessionDeleteConfirmer: SessionSidebarSessionDeleteConfirming {
    private let shouldDelete: Bool
    var requestedIDs: [String] = []

    init(shouldDelete: Bool) {
        self.shouldDelete = shouldDelete
    }

    func shouldDeleteSessions(_ sessions: [SessionRecord], parentWindow: NSWindow?) -> Bool {
        requestedIDs = sessions.map(\.id)
        return shouldDelete
    }
}

private final class RecordingSessionCredentialCleaner: SessionSidebarCredentialCleaning {
    struct Request {
        let previousCredentialID: String?
        let replacementCredentialID: String?
    }

    var requests: [Request] = []

    func cleanupReplacedCredential(previousCredentialID: String?, replacementCredentialID: String?) throws {
        requests.append(
            Request(
                previousCredentialID: previousCredentialID,
                replacementCredentialID: replacementCredentialID
            )
        )
    }
}

private final class RecordingSessionSidebarOperationsPresenter: SessionSidebarOperationsPresenting {
    var moveRequestSessionIDs: [String] = []
    var exportSuggestedNames: [String] = []
    var completedExportURLs: [URL] = []
    var createFolderParentIDs: [String?] = []
    var renameFolderRequestIDs: [String] = []
    var deleteFolderRequestIDs: [String] = []
    var folderExportRequestIDs: [String] = []
    var connectAsRequestSessionIDs: [String] = []
    var pingProgressHosts: [String] = []
    weak var pingProgressPresenter: RecordingSessionSidebarPingProgressPresenter?
    var retainedPingProgressPresenterCount = 0
    var pingResults: [SessionSidebarPingResult] = []
    var renameRequestSessionIDs: [String] = []
    var singleSessionExportRequestIDs: [String] = []
    var shortcutRequestIDs: [String] = []
    var shortcutCreatedURLs: [URL] = []
    var defaultPresetSavedSessionIDs: [String] = []
    var settingsCopiedCount = 0
    private let moveDestination: SessionSidebarMoveDestination?
    private let exportURL: URL?
    private let createFolderName: String?
    private let renameFolderValue: String?
    private let confirmDeleteFolderValue: Bool
    private let folderExportURL: URL?
    private let connectAsUsername: String?
    private let renameValue: String?
    private let singleSessionExportURL: URL?
    private let shortcutURL: URL?

    init(
        moveDestination: SessionSidebarMoveDestination? = nil,
        exportURL: URL? = nil,
        createFolderName: String? = nil,
        renameFolderValue: String? = nil,
        confirmDeleteFolderValue: Bool = true,
        folderExportURL: URL? = nil,
        connectAsUsername: String? = nil,
        renameValue: String? = nil,
        singleSessionExportURL: URL? = nil,
        shortcutURL: URL? = nil
    ) {
        self.moveDestination = moveDestination
        self.exportURL = exportURL
        self.createFolderName = createFolderName
        self.renameFolderValue = renameFolderValue
        self.confirmDeleteFolderValue = confirmDeleteFolderValue
        self.folderExportURL = folderExportURL
        self.connectAsUsername = connectAsUsername
        self.renameValue = renameValue
        self.singleSessionExportURL = singleSessionExportURL
        self.shortcutURL = shortcutURL
    }

    func chooseMoveDestination(
        for session: SessionRecord,
        folders: [SessionFolder],
        parentWindow: NSWindow?
    ) -> SessionSidebarMoveDestination? {
        moveRequestSessionIDs.append(session.id)
        return moveDestination
    }

    func promptCreateFolder(parentFolder: SessionFolder?, parentWindow: NSWindow?) -> String? {
        createFolderParentIDs.append(parentFolder?.id)
        return createFolderName
    }

    func promptRenameFolder(_ folder: SessionFolder, parentWindow: NSWindow?) -> String? {
        renameFolderRequestIDs.append(folder.id)
        return renameFolderValue
    }

    func confirmDeleteFolder(_ folder: SessionFolder, parentWindow: NSWindow?) -> Bool {
        deleteFolderRequestIDs.append(folder.id)
        return confirmDeleteFolderValue
    }

    func chooseFolderExportDestination(folder: SessionFolder, parentWindow: NSWindow?) -> URL? {
        folderExportRequestIDs.append(folder.id)
        return folderExportURL
    }

    func chooseExportDestination(suggestedName: String, parentWindow: NSWindow?) -> URL? {
        exportSuggestedNames.append(suggestedName)
        return exportURL
    }

    func presentExportComplete(destinationURL: URL, parentWindow: NSWindow?) {
        completedExportURLs.append(destinationURL)
    }

    func promptConnectAsUsername(for session: SessionRecord, parentWindow: NSWindow?) -> String? {
        connectAsRequestSessionIDs.append(session.id)
        return connectAsUsername
    }

    func presentPingResult(_ result: SessionSidebarPingResult, parentWindow: NSWindow?) {
        pingResults.append(result)
    }

    func presentPingProgress(host: String, parentWindow: NSWindow?) -> SessionSidebarPingProgressPresenting {
        pingProgressHosts.append(host)
        let presenter = RecordingSessionSidebarPingProgressPresenter()
        presenter.onClose = { [weak self] in
            self?.retainedPingProgressPresenterCount -= 1
        }
        retainedPingProgressPresenterCount += 1
        pingProgressPresenter = presenter
        return presenter
    }

    func promptRenameSession(_ session: SessionRecord, parentWindow: NSWindow?) -> String? {
        renameRequestSessionIDs.append(session.id)
        return renameValue
    }

    func chooseSingleSessionExportDestination(session: SessionRecord, parentWindow: NSWindow?) -> URL? {
        singleSessionExportRequestIDs.append(session.id)
        return singleSessionExportURL
    }

    func chooseDesktopShortcutDestination(session: SessionRecord, parentWindow: NSWindow?) -> URL? {
        shortcutRequestIDs.append(session.id)
        return shortcutURL
    }

    func presentShortcutCreated(destinationURL: URL, parentWindow: NSWindow?) {
        shortcutCreatedURLs.append(destinationURL)
    }

    func presentDefaultPresetSaved(session: SessionRecord, parentWindow: NSWindow?) {
        defaultPresetSavedSessionIDs.append(session.id)
    }

    func presentSettingsCopied(parentWindow: NSWindow?) {
        settingsCopiedCount += 1
    }
}

private final class RecordingSessionSidebarErrorPresenter: SessionSidebarErrorPresenting {
    var contexts: [SessionSidebarErrorContext] = []
    var errors: [Error] = []

    func present(_ error: Error, context: SessionSidebarErrorContext, parentWindow: NSWindow?) {
        errors.append(error)
        contexts.append(context)
    }
}

@MainActor
private final class RecordingLivePingOutput {
    var outputs: [String] = []
    var completed = false
    var results: [SessionSidebarPingResult] = []
    var errors: [Error] = []
}

private final class RecordingSessionSidebarPingProgressPresenter: SessionSidebarPingProgressPresenting {
    var outputs: [String] = []
    var finishedResults: [SessionSidebarPingResult] = []
    var errors: [String] = []
    var onClose: (() -> Void)?
    private var cancelHandler: (@MainActor () -> Void)?
    private var closeHandler: (@MainActor () -> Void)?

    func setCancelHandler(_ handler: @escaping @MainActor () -> Void) {
        cancelHandler = handler
    }

    func setCloseHandler(_ handler: @escaping @MainActor () -> Void) {
        closeHandler = handler
    }

    func appendOutput(_ text: String) {
        outputs.append(text)
    }

    func finish(_ result: SessionSidebarPingResult) {
        finishedResults.append(result)
    }

    func fail(_ error: Error) {
        errors.append(String(describing: error))
    }

    func closeForTesting() {
        closeHandler?()
        onClose?()
    }
}

private final class RecordingSessionSidebarPinger: SessionSidebarHostPinging {
    var hosts: [String] = []
    private var outputHandlers: [@MainActor @Sendable (String) -> Void] = []
    private var completionHandlers: [@MainActor @Sendable (Result<SessionSidebarPingResult, Error>) -> Void] = []

    func ping(
        host: String,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        completion: @escaping @MainActor @Sendable (Result<SessionSidebarPingResult, Error>) -> Void
    ) throws -> SessionSidebarPingRunning {
        hosts.append(host)
        outputHandlers.append(onOutput)
        completionHandlers.append(completion)
        return RecordingSessionSidebarPingRun()
    }

    @MainActor
    func emitOutput(_ text: String, index: Int = 0) {
        outputHandlers[index](text)
    }

    @MainActor
    func finish(_ result: SessionSidebarPingResult, index: Int = 0) {
        completionHandlers[index](.success(result))
    }
}

private final class RecordingSessionSidebarPingRun: SessionSidebarPingRunning {
    private(set) var cancelCount = 0

    func cancel() {
        cancelCount += 1
    }
}

private final class RecordingSessionSidebarShortcutCreator: SessionSidebarShortcutCreating {
    var requests: [(session: SessionRecord, destinationURL: URL)] = []

    func createShortcut(for session: SessionRecord, destinationURL: URL) throws {
        requests.append((session: session, destinationURL: destinationURL))
        try "shortcut".write(to: destinationURL, atomically: true, encoding: .utf8)
    }
}

private final class RecordingSessionSidebarDefaultPresetStore: SessionSidebarDefaultPresetStoring {
    var requests: [(session: SessionRecord, configJSON: String?)] = []

    func saveDefaultPreset(session: SessionRecord, configJSON: String?) throws {
        requests.append((session: session, configJSON: configJSON))
    }
}

private final class RecordingSessionSidebarSettingsCopier: SessionSidebarSettingsCopying {
    var texts: [String] = []

    func copySettings(_ text: String) throws {
        texts.append(text)
    }
}

private extension NSView {
    var textFieldSnapshot: [String] {
        var values: [String] = []
        if let textField = self as? NSTextField {
            values.append(textField.stringValue)
        }
        for subview in subviews {
            values.append(contentsOf: subview.textFieldSnapshot)
        }
        return values
    }

    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }

        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }

        return nil
    }
}

private func makeSidebarHoverEvent(type: NSEvent.EventType) -> NSEvent {
    NSEvent.enterExitEvent(
        with: type,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        trackingNumber: 1,
        userData: nil
    )!
}
