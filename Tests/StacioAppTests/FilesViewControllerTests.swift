import AppKit
import StacioAgentBridge
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class FilesViewControllerTests: XCTestCase {
    func testDirectoryFollowDefaultReadsSettingsStore() throws {
        let suiteName = "StacioFilesDefaultsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.filesDirectoryFollowDefault = false
        }
        let controller = FilesViewController(settingsStore: store)

        _ = controller.view

        let directoryFollowButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.directoryFollow") as? NSButton
        )
        XCTAssertEqual(directoryFollowButton.state, .off)
        XCTAssertFalse(controller.isDirectoryFollowEnabled)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testFilesPanelRendersRemoteEntriesInNativeTable() {
        let controller = FilesViewController()
        controller.loadView()

        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/var/log", size: 0, linkTarget: nil),
            RemoteFileEntry(
                kind: .file,
                path: "/etc/hosts",
                size: 128,
                modifiedTime: "06-02 20:25",
                linkTarget: nil,
                owner: "root",
                permissions: "-rw-r--r--"
            ),
            RemoteFileEntry(kind: .symlink, path: "/usr/bin/python", size: 9, linkTarget: "/usr/bin/python3")
        ])

        XCTAssertEqual(controller.entryCount, 3)
        XCTAssertEqual(controller.tableView.numberOfRows, 3)
        XCTAssertNotNil(controller.tableView.enclosingScrollView)
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["名称", "大小", "用户", "权限", "时间"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 1), "hosts")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 1), "0.12 KB")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 1), "root")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 1), "-rw-r--r--")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 4, row: 1), "06-02 20:25")
        XCTAssertFalse(controller.visibleTextSnapshot.contains("/usr/bin/python3"))
        XCTAssertEqual(controller.engineSummaryText, "")
        XCTAssertFalse(controller.visibleTextSnapshot.contains("内置 SCP"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("rsync"))
    }

    func testFilesPanelSortsHiddenItemsFoldersThenFilesAndShowsTypeIcons() {
        let controller = FilesViewController()
        controller.loadView()

        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/README.md", size: 64, linkTarget: nil),
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/.zprofile", size: 7, linkTarget: nil),
            RemoteFileEntry(kind: .directory, path: "/srv/app/.config", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), ".config")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 1), ".zprofile")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 2), "logs")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 3), "config.json")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 4), "README.md")
        XCTAssertEqual(controller.tableView.viewIconLabel(atColumn: 0, row: 0), "文件夹图标")
        XCTAssertEqual(controller.tableView.viewIconLabel(atColumn: 0, row: 3), "JSON 文件图标")
        XCTAssertNotNil((controller.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.imageView?.image)
        XCTAssertGreaterThanOrEqual(controller.tableView.rowHeight, 34)
        XCTAssertGreaterThanOrEqual(controller.tableView.viewIconSize(atColumn: 0, row: 3)?.width ?? 0, 28)
    }

    func testFilesPanelSortsFromColumnHeadersAndTogglesDirection() {
        let controller = FilesViewController()
        controller.loadView()

        controller.setRemoteEntries([
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/middle.log",
                size: 128,
                modifiedTime: "2024-01-02 10:00",
                linkTarget: nil,
                owner: "deploy",
                permissions: "-rw-r--r--"
            ),
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/small.log",
                size: 64,
                modifiedTime: "2024-01-01 10:00",
                linkTarget: nil,
                owner: "alice",
                permissions: "-rw-------"
            ),
            RemoteFileEntry(
                kind: .file,
                path: "/srv/app/big.log",
                size: 256,
                modifiedTime: "2024-01-03 10:00",
                linkTarget: nil,
                owner: "root",
                permissions: "-rwxr-xr-x"
            )
        ])

        XCTAssertEqual(controller.tableView.tableColumns.map(\.identifier.rawValue), ["name", "size", "owner", "permissions", "time"])
        XCTAssertTrue(controller.tableView.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil })

        controller.sortColumnForTesting(identifier: "size")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "大小（升序）")
        XCTAssertEqual(controller.tableView.sortDescriptors.first?.key, "size")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "small.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 2), "big.log")

        controller.sortColumnForTesting(identifier: "size")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "大小（降序）")
        XCTAssertEqual(controller.tableView.sortDescriptors.first?.ascending, false)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "big.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 2), "small.log")

        controller.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "时间（升序）")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "small.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 2), "big.log")

        controller.sortColumnForTesting(identifier: "time")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "时间（降序）")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "big.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 2), "small.log")

        controller.sortColumnForTesting(identifier: "owner")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "用户（升序）")
        XCTAssertEqual(controller.tableView.sortDescriptors.first?.key, "owner")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "small.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 2), "big.log")

        controller.sortColumnForTesting(identifier: "permissions")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "权限（升序）")
        XCTAssertEqual(controller.tableView.sortDescriptors.first?.key, "permissions")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "small.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 2), "big.log")

        controller.sortColumnForTesting(identifier: "name")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "名称（升序）")
        controller.sortColumnForTesting(identifier: "name")
        XCTAssertEqual(controller.selectedSortModeTitleForTesting, "名称（降序）")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "small.log")
    }

    func testFilesPanelUsesAccessibleEmptyState() {
        let controller = FilesViewController()
        controller.loadView()

        XCTAssertEqual(controller.entryCount, 0)
        XCTAssertEqual(controller.tableView.accessibilityIdentifier(), "Stacio.Files.remoteTable")
        XCTAssertEqual(controller.tableView.accessibilityLabel(), "远端文件")
        XCTAssertTrue(controller.visibleTextSnapshot.contains("暂无远端文件"))
    }

    func testFilesPanelShowsChineseRemoteListingErrorStateAndRestoresEmptyStateAfterSuccess() {
        let controller = FilesViewController()
        controller.loadView()

        controller.setRemoteListingError("权限被拒绝 [已隐藏路径] [已隐藏凭据]")

        XCTAssertEqual(controller.entryCount, 0)
        XCTAssertTrue(controller.visibleTextSnapshot.contains("无法加载远端目录"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("权限被拒绝"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("[已隐藏路径]"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("[已隐藏凭据]"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("Permission denied"))

        controller.setRemoteEntries([])

        XCTAssertTrue(controller.visibleTextSnapshot.contains("暂无远端文件"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("无法加载远端目录"))
    }

    func testFilesPanelExposesNativePathRefreshAndTransferControls() throws {
        let controller = FilesViewController()
        controller.loadView()

        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.refresh") as? NSButton
        )
        let parentButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.parent") as? NSButton
        )
        let toolbar = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.toolbar") as? NSStackView
        )
        let uploadButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.upload") as? NSButton
        )
        let downloadButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.download") as? NSButton
        )
        let moreButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.more") as? NSButton
        )
        let sizeUnitPopup = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.sizeUnit") as? NSPopUpButton
        )
        let sortModePopup = controller.view.firstSubview(withIdentifier: "Stacio.Files.sortMode") as? NSPopUpButton
        let directoryFollowButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.directoryFollow") as? NSButton
        )
        let showHiddenFilesButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.showHiddenFiles") as? NSButton
        )

        XCTAssertEqual(pathField.stringValue, "~")
        XCTAssertEqual(pathField.placeholderString, "远端路径")
        XCTAssertEqual(parentButton.toolTip, "返回上一级目录")
        XCTAssertEqual(refreshButton.toolTip, "刷新远端目录")
        XCTAssertEqual(downloadButton.toolTip, "下载所选项目")
        XCTAssertEqual(uploadButton.toolTip, "上传到当前目录")
        XCTAssertEqual(moreButton.toolTip, "更多")
        XCTAssertNil(sortModePopup)
        XCTAssertTrue([parentButton, refreshButton, uploadButton, downloadButton, moreButton].allSatisfy { $0.title.isEmpty })
        XCTAssertTrue([parentButton, refreshButton, uploadButton, downloadButton, moreButton].allSatisfy { $0.image != nil })
        XCTAssertTrue([parentButton, refreshButton, uploadButton, downloadButton, moreButton].allSatisfy { $0.bezelStyle == .texturedRounded })
        XCTAssertEqual(sizeUnitPopup.itemTitles, ["B", "KB", "MB", "GB", "TB"])
        XCTAssertEqual(sizeUnitPopup.titleOfSelectedItem, "KB")
        XCTAssertEqual(directoryFollowButton.title, "")
        XCTAssertNotNil(directoryFollowButton.image)
        XCTAssertEqual(directoryFollowButton.toolTip, "停止跟随终端目录")
        XCTAssertEqual(directoryFollowButton.state, .on)
        XCTAssertEqual(showHiddenFilesButton.title, "")
        XCTAssertNotNil(showHiddenFilesButton.image)
        XCTAssertEqual(showHiddenFilesButton.state, .on)
        XCTAssertEqual(showHiddenFilesButton.toolTip, "隐藏隐藏文件")
        XCTAssertTrue([directoryFollowButton, showHiddenFilesButton].allSatisfy { $0.bezelStyle == .texturedRounded })
        XCTAssertTrue([directoryFollowButton, showHiddenFilesButton].allSatisfy { $0.imagePosition == .imageOnly })
        XCTAssertTrue([directoryFollowButton, showHiddenFilesButton].allSatisfy { button in
            button.constraints.contains { $0.firstAttribute == .width && $0.constant == 26 }
        })
        XCTAssertTrue(toolbar.arrangedSubviews.contains { $0 === parentButton })
        XCTAssertTrue(toolbar.arrangedSubviews.contains { $0 === directoryFollowButton })
        XCTAssertTrue(toolbar.arrangedSubviews.contains { $0 === showHiddenFilesButton })
        XCTAssertTrue(controller.isDirectoryFollowEnabled)
        XCTAssertTrue(controller.isShowingHiddenFiles)
        directoryFollowButton.performClick(nil)
        XCTAssertEqual(directoryFollowButton.state, .off)
        XCTAssertEqual(directoryFollowButton.toolTip, "跟随终端 cd 命令切换目录")
        XCTAssertFalse(controller.isDirectoryFollowEnabled)
        showHiddenFilesButton.performClick(nil)
        XCTAssertEqual(showHiddenFilesButton.state, .off)
        XCTAssertEqual(showHiddenFilesButton.toolTip, "显示隐藏文件")
        XCTAssertFalse(controller.isShowingHiddenFiles)
        XCTAssertEqual(controller.uploadMenuTitlesForTesting, [
            "上传文件",
            "上传文件夹"
        ])
        XCTAssertFalse(controller.tableView.usesAlternatingRowBackgroundColors)
        XCTAssertEqual(controller.tableView.backgroundColor, .clear)
        XCTAssertEqual(controller.moreMenuTitlesForTesting, [
            "新建远端目录",
            "新建远端文件",
            "重命名远端项目",
            "删除远端项目",
            "编辑本地副本",
            "保存编辑副本",
            "同步已变更编辑文件",
            "修改远端权限"
        ])
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("SCP"))
        XCTAssertFalse(controller.visibleTextSnapshot.localizedCaseInsensitiveContains("SFTP"))
    }

    func testFilesPanelSearchResultsCloseWithEscapeAndRestoreDirectoryBrowsing() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/README.md", size: 128, linkTarget: nil)
        ], remotePath: "/srv/app")
        controller.setRemoteSearchAvailable(true)

        let searchButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.search") as? NSButton
        )
        searchButton.performClick(nil)

        let searchField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.searchField") as? NSSearchField
        )
        let depthField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.searchDepth") as? NSTextField
        )
        searchField.stringValue = "log"
        depthField.stringValue = "5"

        controller.setRemoteSearchResults([
            RemoteFileEntry(kind: .file, path: "/srv/app/logs/app.log", size: 64, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config/logging.yml", size: 96, linkTarget: nil)
        ], baseDirectory: "/srv/app", keyword: "log")

        XCTAssertTrue(controller.isRemoteSearchActiveForTesting)
        XCTAssertEqual(controller.entryCount, 2)
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["名称", "相对路径", "用户", "权限", "时间"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "app.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "logs/app.log")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "—")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 3, row: 0), "—")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 1), "logging.yml")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 1), "config/logging.yml")

        XCTAssertTrue(performEscapeShortcut(on: controller.view))

        XCTAssertFalse(controller.isRemoteSearchActiveForTesting)
        XCTAssertEqual(controller.currentRemotePath, "/srv/app")
        XCTAssertEqual(controller.entryCount, 2)
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["名称", "大小", "用户", "权限", "时间"])
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "logs")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 1), "README.md")
    }

    func testFilesPanelFiltersHiddenEntriesWithoutReloadingRemoteListing() throws {
        let suiteName = "StacioFilesHiddenDefaultsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.filesShowHiddenFilesByDefault = false
        }
        let controller = FilesViewController(settingsStore: store)
        controller.loadView()

        let showHiddenFilesButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.showHiddenFiles") as? NSButton
        )
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/.env", size: 64, linkTarget: nil),
            RemoteFileEntry(kind: .directory, path: "/srv/app/.config", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/README.md", size: 128, linkTarget: nil)
        ])

        XCTAssertFalse(controller.isShowingHiddenFiles)
        XCTAssertEqual(showHiddenFilesButton.state, .off)
        XCTAssertEqual(controller.entryCount, 2)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), "logs")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 1), "README.md")
        XCTAssertFalse(controller.visibleTextSnapshot.contains(".env"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains(".config"))

        showHiddenFilesButton.performClick(nil)

        XCTAssertTrue(controller.isShowingHiddenFiles)
        XCTAssertEqual(showHiddenFilesButton.state, .on)
        XCTAssertEqual(controller.entryCount, 4)
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), ".config")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 1), ".env")
        XCTAssertTrue(controller.visibleTextSnapshot.contains("README.md"))
    }

    func testFilesPanelExplainsEmptyStateWhenOnlyHiddenEntriesAreFiltered() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setShowHiddenFilesEnabled(false)

        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/home/deploy/.bashrc", size: 42, linkTarget: nil)
        ])

        XCTAssertEqual(controller.entryCount, 0)
        XCTAssertTrue(controller.visibleTextSnapshot.contains("隐藏文件已隐藏"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("显示隐藏文件"))
    }

    func testParentDirectoryButtonRequestsParentPath() throws {
        let controller = FilesViewController()
        controller.loadView()
        var requestedPaths: [String] = []
        controller.onRefresh = { requestedPaths.append($0) }
        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        let parentButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.parent") as? NSButton
        )

        XCTAssertFalse(parentButton.isEnabled)

        pathField.stringValue = "/var/log/nginx"
        controller.updateActionStatesForTesting()
        parentButton.performClick(nil as Any?)

        XCTAssertEqual(pathField.stringValue, "/var/log")
        XCTAssertEqual(requestedPaths, ["/var/log"])

        pathField.stringValue = "~/project"
        controller.updateActionStatesForTesting()
        parentButton.performClick(nil as Any?)

        XCTAssertEqual(pathField.stringValue, "~")
        XCTAssertEqual(requestedPaths, ["/var/log", "~"])

        pathField.stringValue = "/"
        controller.updateActionStatesForTesting()

        XCTAssertFalse(parentButton.isEnabled)
    }

    func testFilesPanelUpdatesActionEnabledStatesForCurrentSelection() throws {
        let controller = FilesViewController()
        controller.loadView()
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.refresh") as? NSButton
        )
        let uploadButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.upload") as? NSButton
        )
        let downloadButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.download") as? NSButton
        )
        let moreButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.more") as? NSButton
        )

        assertFilesActionState(
            controller,
            refreshButton: refreshButton,
            uploadButton: uploadButton,
            downloadButton: downloadButton,
            moreButton: moreButton,
            canDownload: false,
            canRename: false,
            canDelete: false,
            canChmod: false
        )

        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        assertFilesActionState(
            controller,
            refreshButton: refreshButton,
            uploadButton: uploadButton,
            downloadButton: downloadButton,
            moreButton: moreButton,
            canDownload: false,
            canRename: false,
            canDelete: false,
            canChmod: false
        )

        controller.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        assertFilesActionState(
            controller,
            refreshButton: refreshButton,
            uploadButton: uploadButton,
            downloadButton: downloadButton,
            moreButton: moreButton,
            canDownload: true,
            canRename: true,
            canDelete: true,
            canChmod: true
        )

        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        assertFilesActionState(
            controller,
            refreshButton: refreshButton,
            uploadButton: uploadButton,
            downloadButton: downloadButton,
            moreButton: moreButton,
            canDownload: true,
            canRename: true,
            canDelete: true,
            canChmod: true
        )
    }

    func testFilesInspectorTablePreservesReadableColumnsWithHorizontalScrolling() {
        let controller = FilesViewController()
        controller.loadView()

        let scrollView = controller.tableView.enclosingScrollView
        let totalColumnWidth = controller.tableView.tableColumns.reduce(CGFloat(0)) { partialResult, column in
            partialResult + column.width
        }

        XCTAssertEqual(scrollView?.hasHorizontalScroller, true)
        XCTAssertGreaterThanOrEqual(totalColumnWidth, 480)
        XCTAssertEqual(scrollView?.layer?.borderWidth ?? 0, 0)
        XCTAssertLessThanOrEqual(scrollView?.layer?.cornerRadius ?? 0, 0)
    }

    func testFilesInspectorKeepsColumnsReadableInCompactPanel() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 284, height: 520)
        controller.view.layoutSubtreeIfNeeded()

        let nameColumn = try XCTUnwrap(controller.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")))
        let sizeColumn = try XCTUnwrap(controller.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size")))
        let ownerColumn = try XCTUnwrap(controller.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("owner")))
        let permissionsColumn = try XCTUnwrap(controller.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("permissions")))
        let timeColumn = try XCTUnwrap(controller.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("time")))
        let scrollView = try XCTUnwrap(controller.tableView.enclosingScrollView)
        let visibleTableWidth = scrollView.contentView.bounds.width
        let totalColumnWidth = controller.tableView.tableColumns.reduce(CGFloat(0)) { partialResult, column in
            partialResult + column.width
        }

        XCTAssertGreaterThan(visibleTableWidth, 0)
        XCTAssertGreaterThanOrEqual(nameColumn.width, 180)
        XCTAssertGreaterThanOrEqual(sizeColumn.width, 64)
        XCTAssertGreaterThanOrEqual(ownerColumn.width, 56)
        XCTAssertGreaterThanOrEqual(permissionsColumn.width, 72)
        XCTAssertGreaterThanOrEqual(timeColumn.width, 112)
        XCTAssertGreaterThan(totalColumnWidth, visibleTableWidth)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
    }

    func testFilesInspectorPreservesUserResizedMetadataColumnAfterLayout() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        controller.view.layoutSubtreeIfNeeded()

        let sizeColumn = try XCTUnwrap(
            controller.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size"))
        )
        sizeColumn.width = 144
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.tableView.columnAutoresizingStyle, .firstColumnOnlyAutoresizingStyle)
        XCTAssertEqual(sizeColumn.width, 144)
    }

    func testFilesInspectorUsesCompactHeaderAndReadablePathRow() throws {
        let controller = FilesViewController()
        controller.loadView()

        let toolbar = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.toolbar") as? NSStackView
        )
        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        let pathFieldCell = try XCTUnwrap(pathField.cell as? NSTextFieldCell)

        XCTAssertEqual(toolbar.orientation, .horizontal)
        XCTAssertEqual(toolbar.alignment, .centerY)
        XCTAssertGreaterThanOrEqual(pathField.fittingSize.height, 30)
        XCTAssertLessThanOrEqual(pathField.fittingSize.height, 34)
        XCTAssertEqual(pathFieldCell.drawingRect(forBounds: NSRect(x: 0, y: 0, width: 260, height: 32)).midY, 16, accuracy: 1)
    }

    func testFilesPanelShowsCurrentDirectoryInPathFieldAndBasenamesInRows() throws {
        let controller = FilesViewController()
        controller.loadView()

        controller.setCurrentRemotePath("/root")
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/root/.bashrc", size: 3_106, linkTarget: nil),
            RemoteFileEntry(kind: .directory, path: "/root/.config", size: 4_096, linkTarget: nil)
        ])

        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        XCTAssertEqual(pathField.stringValue, "/root")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 0), ".bashrc")
        XCTAssertEqual(controller.tableView.viewText(atColumn: 0, row: 1), ".config")
        XCTAssertFalse(controller.visibleTextSnapshot.contains("/root/.bashrc"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("/root/.config"))
    }

    func testFilesPanelLetsUserSwitchSizeUnits() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/root/archive.tar.gz", size: 2_828_921, linkTarget: nil)
        ])
        let sizeUnitPopup = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.sizeUnit") as? NSPopUpButton
        )

        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "2762.62 KB")

        controller.selectSizeUnitForTesting("MB")

        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "2.70 MB")
        XCTAssertEqual(sizeUnitPopup.titleOfSelectedItem, "MB")

        controller.selectSizeUnitForTesting("GB")

        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "0.00 GB")
    }

    func testRefreshButtonRequestsCurrentPath() throws {
        let controller = FilesViewController()
        controller.loadView()
        var requestedPaths: [String] = []
        controller.onRefresh = { requestedPaths.append($0) }
        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        let refreshButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.refresh") as? NSButton
        )

        pathField.stringValue = "/var/log"
        refreshButton.performClick(nil as Any?)

        XCTAssertEqual(requestedPaths, ["/var/log"])
    }

    func testDoubleClickDirectoryOpensDirectoryTextFileMediaAndUnknownFilesInsideStacio() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/etc/ssh/sshd_config", size: 256, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/.env.local", size: 96, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/demo.mov", size: 1_024, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/archive.bin", size: 2_048, linkTarget: nil)
        ])
        var openedPaths: [String] = []
        var editedPaths: [String] = []
        var previewedPaths: [String] = []
        var defaultApplicationPaths: [String] = []
        controller.onOpenDirectory = { openedPaths.append($0) }
        controller.onOpenRemoteEdit = { editedPaths.append($0.path) }
        controller.onOpenRemotePreview = { previewedPaths.append($0.path) }
        controller.onOpenRemoteWithDefaultApplication = { defaultApplicationPaths.append($0.path) }

        openEntry(named: "app", controller: controller)
        openEntry(named: "config.json", controller: controller)
        openEntry(named: "sshd_config", controller: controller)
        openEntry(named: ".env.local", controller: controller)
        openEntry(named: "demo.mov", controller: controller)
        openEntry(named: "archive.bin", controller: controller)

        XCTAssertEqual(openedPaths, ["/srv/app"])
        XCTAssertEqual(editedPaths, [
            "/srv/app/config.json",
            "/etc/ssh/sshd_config",
            "/srv/app/.env.local",
            "/srv/app/archive.bin"
        ])
        XCTAssertEqual(previewedPaths, ["/srv/app/demo.mov"])
        XCTAssertTrue(defaultApplicationPaths.isEmpty)
    }

    func testLinuxConfigurationAndUnknownFileNamesOpenAsEditableTextByDefault() {
        let editableNames = [
            "sshd_config",
            "sudoers",
            "fstab",
            "crontab",
            "authorized_keys",
            ".npmrc",
            ".gitignore",
            ".env.production",
            "default",
            "10-eth0.network",
            "nginx.service",
            "sources.list",
            "CentOS-Base.repo",
            "archive.bin",
            "README-without-extension",
            "custom.unknown"
        ]

        for fileName in editableNames {
            XCTAssertEqual(StacioFileDisplay.contentKind(forFileName: fileName), .text, fileName)
        }
        XCTAssertEqual(StacioFileDisplay.contentKind(forFileName: "screenshot.png"), .image)
        XCTAssertEqual(StacioFileDisplay.contentKind(forFileName: "clip.mp3"), .audio)
        XCTAssertEqual(StacioFileDisplay.contentKind(forFileName: "demo.webm"), .video)
    }

    func testCommonMediaFileNamesOpenInPreviewMode() {
        let imageNames = [
            "photo.jpg",
            "photo.jpeg",
            "diagram.png",
            "animation.gif",
            "icon.bmp",
            "poster.webp",
            "vector.svg",
            "favicon.ico"
        ]
        let audioNames = [
            "song.mp3",
            "voice.wav",
            "loop.ogg",
            "sample.aac",
            "master.flac",
            "podcast.m4a"
        ]
        let videoNames = [
            "movie.mp4",
            "clip.webm",
            "capture.avi",
            "recording.mov",
            "archive.mkv"
        ]

        for fileName in imageNames {
            XCTAssertEqual(StacioFileDisplay.contentKind(forFileName: fileName), .image, fileName)
        }
        for fileName in audioNames {
            XCTAssertEqual(StacioFileDisplay.contentKind(forFileName: fileName), .audio, fileName)
        }
        for fileName in videoNames {
            XCTAssertEqual(StacioFileDisplay.contentKind(forFileName: fileName), .video, fileName)
        }
    }

    func testEmbeddedEditorDefaultsWideAndCanBeDraggedWider() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let fileURL = try makeTemporaryEditorFile(name: "sshd_config", contents: "PermitRootLogin no\n")

        controller.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()

        let splitView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.editorSplit") as? NSSplitView
        )
        let editor = try XCTUnwrap(controller.embeddedEditorViewControllerForTesting)
        let initialEditorFrame = editor.view.convert(editor.view.bounds, to: controller.view)
        let initialBrowserFrame = controller.fileBrowserPaneViewForTesting.convert(
            controller.fileBrowserPaneViewForTesting.bounds,
            to: controller.view
        )

        XCTAssertTrue(splitView.arrangedSubviews[0] === editor.view)
        XCTAssertTrue(splitView.arrangedSubviews[1] === controller.fileBrowserPaneViewForTesting)
        XCTAssertLessThan(initialEditorFrame.minX, initialBrowserFrame.minX)
        XCTAssertGreaterThanOrEqual(initialEditorFrame.width, 680)
        XCTAssertGreaterThanOrEqual(initialBrowserFrame.width, 240)

        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
        splitView.setPosition(1_050, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let draggedEditorFrame = editor.view.convert(editor.view.bounds, to: controller.view)
        let draggedBrowserFrame = controller.fileBrowserPaneViewForTesting.convert(
            controller.fileBrowserPaneViewForTesting.bounds,
            to: controller.view
        )
        XCTAssertGreaterThan(draggedEditorFrame.width, initialEditorFrame.width)
        XCTAssertGreaterThanOrEqual(draggedEditorFrame.width, 900)
        XCTAssertGreaterThanOrEqual(draggedBrowserFrame.width, 240)
        XCTAssertLessThan(draggedEditorFrame.minX, draggedBrowserFrame.minX)
    }

    func testEmbeddedEditorFileBrowserCanCollapseAndRestoreWithShortcutAction() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let fileURL = try makeTemporaryEditorFile(name: "service.conf", contents: "enabled=true\n")

        controller.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        controller.view.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(controller.embeddedEditorViewControllerForTesting)
        let expandedFrame = editor.view.convert(editor.view.bounds, to: controller.view)

        XCTAssertTrue(performControlBShortcut(on: controller.view))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.fileBrowserPaneViewForTesting.isHidden)
        let collapsedFrame = editor.view.convert(editor.view.bounds, to: controller.view)
        XCTAssertGreaterThan(collapsedFrame.width, expandedFrame.width)

        XCTAssertTrue(performControlBShortcut(on: controller.view))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.fileBrowserPaneViewForTesting.isHidden)
        let restoredFrame = editor.view.convert(editor.view.bounds, to: controller.view)
        XCTAssertLessThan(restoredFrame.width, collapsedFrame.width)
    }

    func testEmbeddedEditorCanCollapseToFloatingExpandButtonAndRestoreState() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let fileURL = try makeTemporaryEditorFile(name: "service.conf", contents: "enabled=true\n")

        controller.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        controller.view.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(controller.embeddedEditorViewControllerForTesting)

        controller.collapseEmbeddedCapabilityForTesting()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.isEmbeddedCapabilityCollapsedForTesting)
        XCTAssertTrue(editor.view.isHidden)
        XCTAssertFalse(controller.fileBrowserPaneViewForTesting.isHidden)
        let expandButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.expandEmbeddedCapability") as? NSButton
        )
        XCTAssertFalse(expandButton.isHidden)
        XCTAssertEqual(editor.activeFileNameForTesting, "service.conf")

        expandButton.performClick(nil as Any?)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(controller.isEmbeddedCapabilityCollapsedForTesting)
        XCTAssertFalse(editor.view.isHidden)
        XCTAssertTrue(expandButton.isHidden)
        XCTAssertEqual(editor.activeFileNameForTesting, "service.conf")
    }

    func testCollapsedEmbeddedEditorRestoresUserAdjustedFileBrowserWidth() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 640)
        let fileURL = try makeTemporaryEditorFile(name: "service.conf", contents: "enabled=true\n")

        controller.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        controller.view.layoutSubtreeIfNeeded()
        let splitView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.editorSplit") as? NSSplitView
        )
        splitView.setPosition(650, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        let browserWidthBeforeCollapse = controller.fileBrowserPaneViewForTesting.convert(
            controller.fileBrowserPaneViewForTesting.bounds,
            to: controller.view
        ).width

        controller.collapseEmbeddedCapabilityForTesting()
        let expandButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.expandEmbeddedCapability") as? NSButton
        )
        expandButton.performClick(nil as Any?)
        controller.view.layoutSubtreeIfNeeded()

        let restoredBrowserWidth = controller.fileBrowserPaneViewForTesting.convert(
            controller.fileBrowserPaneViewForTesting.bounds,
            to: controller.view
        ).width
        XCTAssertEqual(restoredBrowserWidth, browserWidthBeforeCollapse, accuracy: 1)
    }

    func testEmbeddedMediaPreviewUsesEditorTabsInsteadOfReplacingTheEditor() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let textURL = try makeTemporaryEditorFile(name: "service.conf", contents: "enabled=true\n")
        let imageURL = try makeTemporaryEditorFile(name: "screenshot.png", data: Data([0x89, 0x50, 0x4e, 0x47]))

        controller.presentEmbeddedEditor(localURL: textURL, saveHandler: nil)
        controller.presentEmbeddedMediaPreview(localURL: imageURL)
        controller.view.layoutSubtreeIfNeeded()

        let editor = try XCTUnwrap(controller.embeddedEditorViewControllerForTesting)
        XCTAssertNil(controller.embeddedMediaPreviewViewControllerForTesting)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.MediaPreview.root"))
        XCTAssertEqual(editor.tabTitlesForTesting, ["service.conf", "screenshot.png"])
        XCTAssertEqual(editor.activeFileNameForTesting, "screenshot.png")
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "image")
    }

    func testEmbeddedMediaPreviewCreatesEditorWorkspaceWhenOpenedFirst() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 980, height: 640)
        let imageURL = try makeTemporaryEditorFile(name: "screenshot.png", data: Data([0x89, 0x50, 0x4e, 0x47]))

        controller.presentEmbeddedMediaPreview(localURL: imageURL)
        controller.view.layoutSubtreeIfNeeded()

        let editor = try XCTUnwrap(controller.embeddedEditorViewControllerForTesting)
        XCTAssertNil(controller.embeddedMediaPreviewViewControllerForTesting)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Editor.root"))
        XCTAssertEqual(editor.tabTitlesForTesting, ["screenshot.png"])
        XCTAssertEqual(editor.activeDocumentDisplayModeForTesting, "image")
    }

    func testDownloadButtonRequestsSelectedFilesAndDirectories() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/readme.md", size: 256, linkTarget: nil)
        ])
        var downloadedSelections: [[RemoteFileSelection]] = []
        controller.onDownloadSelections = { downloadedSelections.append($0) }

        controller.tableView.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        controller.performDownloadSelectedEntryForTesting()

        XCTAssertEqual(downloadedSelections, [[
            RemoteFileSelection(path: "/srv/app", size: 0, kind: .directory),
            RemoteFileSelection(path: "/srv/app/config.json", size: 128, kind: .file),
            RemoteFileSelection(path: "/srv/app/readme.md", size: 256, kind: .file)
        ]])
    }

    func testUploadMenuRequestsCurrentRemotePathForFilesAndFolders() throws {
        let controller = FilesViewController()
        controller.loadView()
        var fileUploadTargetPaths: [String] = []
        var folderUploadTargetPaths: [String] = []
        controller.onUploadFile = { fileUploadTargetPaths.append($0) }
        controller.onUploadFolder = { folderUploadTargetPaths.append($0) }
        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        controller.performUploadFileForTesting()
        controller.performUploadFolderForTesting()

        XCTAssertEqual(fileUploadTargetPaths, ["/srv/app"])
        XCTAssertEqual(folderUploadTargetPaths, ["/srv/app"])
    }

    func testDroppedFinderFilesRequestUploadToCurrentRemotePath() throws {
        let controller = FilesViewController()
        controller.loadView()
        var droppedUploads: [(remoteDirectory: String, localPaths: [String])] = []
        controller.onUploadDroppedFiles = { remoteDirectory, localPaths in
            droppedUploads.append((remoteDirectory, localPaths))
        }
        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )

        pathField.stringValue = "/srv/app"
        controller.performDropLocalFilesForTesting([
            "/Users/alice/build.zip",
            "/Users/alice/config.json"
        ])

        XCTAssertEqual(droppedUploads.map(\.remoteDirectory), ["/srv/app"])
        XCTAssertEqual(droppedUploads.first?.localPaths, [
            "/Users/alice/build.zip",
            "/Users/alice/config.json"
        ])
    }

    func testFilesPanelRootAcceptsFinderFileDropsForUpload() {
        let controller = FilesViewController()
        controller.loadView()
        let scrollView = controller.tableView.enclosingScrollView

        XCTAssertTrue(controller.tableView.registeredDraggedTypes.contains(.fileURL))
        XCTAssertTrue(scrollView?.registeredDraggedTypes.contains(.fileURL) ?? false)
        XCTAssertTrue(scrollView?.contentView.registeredDraggedTypes.contains(.fileURL) ?? false)
        XCTAssertTrue(controller.view.registeredDraggedTypes.contains(.fileURL))
    }

    func testRemoteOperationButtonsRequestCurrentSelectionAndDirectory() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/run.sh", size: 128, linkTarget: nil)
        ])
        var mkdirPaths: [String] = []
        var newFilePaths: [String] = []
        var renameSelections: [RemoteFileSelection] = []
        var deleteSelections: [RemoteFileSelection] = []
        var editSelections: [RemoteFileSelection] = []
        var saveSelections: [RemoteFileSelection] = []
        var syncEditedCopiesCount = 0
        var chmodSelections: [RemoteFileSelection] = []
        controller.onCreateDirectory = { mkdirPaths.append($0) }
        controller.onCreateFile = { newFilePaths.append($0) }
        controller.onRenamePath = { renameSelections.append($0) }
        controller.onDeletePath = { deleteSelections.append($0) }
        controller.onOpenRemoteEdit = { editSelections.append($0) }
        controller.onSaveRemoteEdit = { saveSelections.append($0) }
        controller.onSyncChangedRemoteEdits = { syncEditedCopiesCount += 1 }
        controller.onChmodPath = { chmodSelections.append($0) }
        let pathField = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.pathField") as? NSTextField
        )
        let moreButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.more") as? NSButton
        )

        pathField.stringValue = "/srv/app"
        controller.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(moreButton.toolTip, "更多")
        controller.performMoreActionForTesting(title: "新建远端目录")
        controller.performMoreActionForTesting(title: "新建远端文件")
        controller.performMoreActionForTesting(title: "重命名远端项目")
        controller.performMoreActionForTesting(title: "删除远端项目")
        controller.performMoreActionForTesting(title: "编辑本地副本")
        controller.performMoreActionForTesting(title: "保存编辑副本")
        controller.performMoreActionForTesting(title: "同步已变更编辑文件")
        controller.performMoreActionForTesting(title: "修改远端权限")

        XCTAssertEqual(mkdirPaths, ["/srv/app"])
        XCTAssertEqual(newFilePaths, ["/srv/app"])
        XCTAssertEqual(renameSelections, [RemoteFileSelection(path: "/srv/app/run.sh", size: 128)])
        XCTAssertEqual(deleteSelections, [RemoteFileSelection(path: "/srv/app/run.sh", size: 128)])
        XCTAssertEqual(editSelections, [RemoteFileSelection(path: "/srv/app/run.sh", size: 128)])
        XCTAssertEqual(saveSelections, [RemoteFileSelection(path: "/srv/app/run.sh", size: 128)])
        XCTAssertEqual(syncEditedCopiesCount, 1)
        XCTAssertEqual(chmodSelections, [RemoteFileSelection(path: "/srv/app/run.sh", size: 128)])
    }

    func testFolderContextMenuExposesRequestedActions() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 4_096, linkTarget: nil)
        ])

        XCTAssertEqual(controller.contextMenuTitlesForTesting(row: 0), [
            "新建远端目录",
            "新建远端文件",
            "打开",
            "下载",
            "删除",
            "重命名",
            "复制文件路径",
            "将文件路径复制到终端",
            "属性",
            "权限"
        ])
    }

    func testFolderContextMenuActionsUseRealRemoteSelectionCallbacks() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil)
        ])
        var openedPaths: [String] = []
        var mkdirPaths: [String] = []
        var newFilePaths: [String] = []
        var downloadedSelections: [[RemoteFileSelection]] = []
        var deleteSelections: [RemoteFileSelection] = []
        var renameSelections: [RemoteFileSelection] = []
        var chmodSelections: [RemoteFileSelection] = []
        controller.onOpenDirectory = { openedPaths.append($0) }
        controller.onCreateDirectory = { mkdirPaths.append($0) }
        controller.onCreateFile = { newFilePaths.append($0) }
        controller.onDownloadSelections = { downloadedSelections.append($0) }
        controller.onDeletePath = { deleteSelections.append($0) }
        controller.onRenamePath = { renameSelections.append($0) }
        controller.onChmodPath = { chmodSelections.append($0) }

        controller.performContextMenuActionForTesting(title: "新建远端目录", row: 0)
        controller.performContextMenuActionForTesting(title: "新建远端文件", row: 0)
        controller.performContextMenuActionForTesting(title: "打开", row: 0)
        controller.performContextMenuActionForTesting(title: "下载", row: 0)
        controller.performContextMenuActionForTesting(title: "删除", row: 0)
        controller.performContextMenuActionForTesting(title: "重命名", row: 0)
        controller.performContextMenuActionForTesting(title: "权限", row: 0)

        let selection = RemoteFileSelection(path: "/srv/app/logs", size: 0, kind: .directory)
        XCTAssertEqual(mkdirPaths, ["/srv/app"])
        XCTAssertEqual(newFilePaths, ["/srv/app"])
        XCTAssertEqual(openedPaths, ["/srv/app/logs"])
        XCTAssertEqual(downloadedSelections, [[selection]])
        XCTAssertEqual(deleteSelections, [selection])
        XCTAssertEqual(renameSelections, [selection])
        XCTAssertEqual(chmodSelections, [selection])
    }

    func testContextDeleteUsesSelectedFilesAndDirectoriesWhenClickedRowIsSelected() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/readme.md", size: 256, linkTarget: nil)
        ])
        var deletedSelections: [[RemoteFileSelection]] = []
        var legacyDeletedSelections: [RemoteFileSelection] = []
        controller.onDeleteSelections = { deletedSelections.append($0) }
        controller.onDeletePath = { legacyDeletedSelections.append($0) }

        controller.tableView.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        controller.performContextMenuActionForTesting(title: "删除", row: 1)

        XCTAssertEqual(deletedSelections, [[
            RemoteFileSelection(path: "/srv/app/logs", size: 0, kind: .directory),
            RemoteFileSelection(path: "/srv/app/config.json", size: 128, kind: .file),
            RemoteFileSelection(path: "/srv/app/readme.md", size: 256, kind: .file)
        ]])
        XCTAssertTrue(legacyDeletedSelections.isEmpty)
    }

    func testFolderContextMenuCopiesFullPathAndSendsPathToTerminal() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 0, linkTarget: nil)
        ])
        var terminalPaths: [String] = []
        controller.onSendPathToTerminal = { terminalPaths.append($0) }
        NSPasteboard.general.clearContents()

        controller.performContextMenuActionForTesting(title: "复制文件路径", row: 0)
        controller.performContextMenuActionForTesting(title: "将文件路径复制到终端", row: 0)
        controller.performMiddleClickPathToTerminalForTesting(row: 0)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/srv/app/logs")
        XCTAssertEqual(terminalPaths, ["/srv/app/logs", "/srv/app/logs"])
    }

    func testFolderContextMenuPropertiesShowsUsableDetails() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .directory, path: "/srv/app/logs", size: 4_096, linkTarget: nil)
        ])

        controller.performContextMenuActionForTesting(title: "属性", row: 0)

        let text = try XCTUnwrap(controller.lastPresentedPropertiesTextForTesting)
        XCTAssertTrue(text.contains("名称：logs"))
        XCTAssertTrue(text.contains("类型：目录"))
        XCTAssertTrue(text.contains("路径：/srv/app/logs"))
        XCTAssertTrue(text.contains("用户：—"))
        XCTAssertTrue(text.contains("权限：—"))
        XCTAssertTrue(text.contains("大小：4.00 KB"))
    }

    func testFileContextMenuExposesRequestedActions() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])

        XCTAssertEqual(controller.contextMenuTitlesForTesting(row: 0), [
            "新建远端目录",
            "新建远端文件",
            "打开",
            "在 Stacio 编辑器中打开",
            "打开方式...",
            "使用默认程序打开...",
            "比较文件...",
            "下载",
            "删除",
            "重命名",
            "复制文件路径",
            "将文件名复制到终端（单击鼠标中键）",
            "属性",
            "权限"
        ])
    }

    func testFileContextMenuActionsUseRealRemoteSelectionCallbacks() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])
        var editedSelections: [RemoteFileSelection] = []
        var openedWithSelections: [RemoteFileSelection] = []
        var openedDefaultSelections: [RemoteFileSelection] = []
        var comparedSelections: [[RemoteFileSelection]] = []
        var downloadedSelections: [[RemoteFileSelection]] = []
        var deletedSelections: [RemoteFileSelection] = []
        var renamedSelections: [RemoteFileSelection] = []
        var chmodSelections: [RemoteFileSelection] = []
        controller.onOpenRemoteEdit = { editedSelections.append($0) }
        controller.onOpenRemoteWith = { openedWithSelections.append($0) }
        controller.onOpenRemoteWithDefaultApplication = { openedDefaultSelections.append($0) }
        controller.onCompareFiles = { comparedSelections.append($0) }
        controller.onDownloadSelections = { downloadedSelections.append($0) }
        controller.onDeletePath = { deletedSelections.append($0) }
        controller.onRenamePath = { renamedSelections.append($0) }
        controller.onChmodPath = { chmodSelections.append($0) }

        controller.performContextMenuActionForTesting(title: "打开", row: 0)
        controller.performContextMenuActionForTesting(title: "在 Stacio 编辑器中打开", row: 0)
        controller.performContextMenuActionForTesting(title: "打开方式...", row: 0)
        controller.performContextMenuActionForTesting(title: "使用默认程序打开...", row: 0)
        controller.performContextMenuActionForTesting(title: "比较文件...", row: 0)
        controller.performContextMenuActionForTesting(title: "下载", row: 0)
        controller.performContextMenuActionForTesting(title: "删除", row: 0)
        controller.performContextMenuActionForTesting(title: "重命名", row: 0)
        controller.performContextMenuActionForTesting(title: "权限", row: 0)

        let selection = RemoteFileSelection(path: "/srv/app/config.json", size: 128)
        XCTAssertEqual(editedSelections, [selection, selection])
        XCTAssertEqual(openedWithSelections, [selection])
        XCTAssertEqual(openedDefaultSelections, [selection])
        XCTAssertEqual(comparedSelections, [[selection]])
        XCTAssertEqual(downloadedSelections, [[selection]])
        XCTAssertEqual(deletedSelections, [selection])
        XCTAssertEqual(renamedSelections, [selection])
        XCTAssertEqual(chmodSelections, [selection])
    }

    func testFileContextMenuCopiesFullPathAndSendsFileNameToTerminal() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil)
        ])
        var terminalTexts: [String] = []
        controller.onSendPathToTerminal = { terminalTexts.append($0) }
        NSPasteboard.general.clearContents()

        controller.performContextMenuActionForTesting(title: "复制文件路径", row: 0)
        controller.performContextMenuActionForTesting(title: "将文件名复制到终端（单击鼠标中键）", row: 0)
        controller.performMiddleClickPathToTerminalForTesting(row: 0)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/srv/app/config.json")
        XCTAssertEqual(terminalTexts, ["config.json", "config.json"])
    }

    func testFileContextMenuCompareUsesSelectedFilesWhenMultipleFilesAreSelected() {
        let controller = FilesViewController()
        controller.loadView()
        controller.setRemoteEntries([
            RemoteFileEntry(kind: .file, path: "/srv/app/config.json", size: 128, linkTarget: nil),
            RemoteFileEntry(kind: .file, path: "/srv/app/config.old.json", size: 64, linkTarget: nil)
        ])
        var comparedSelections: [[RemoteFileSelection]] = []
        controller.onCompareFiles = { comparedSelections.append($0) }

        controller.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        controller.performContextMenuActionForTesting(title: "比较文件...", row: 0)

        XCTAssertEqual(comparedSelections, [[
            RemoteFileSelection(path: "/srv/app/config.json", size: 128),
            RemoteFileSelection(path: "/srv/app/config.old.json", size: 64)
        ]])
    }

    func testInspectorFilesTabHostsFilesController() {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())
        controller.loadView()

        XCTAssertNotNil(controller.filesViewController)
        XCTAssertEqual(controller.sectionLabelsForTesting, ["文件", "隧道", "浏览器", "诊断", "宏", "历史命令", "AI"])
        XCTAssertTrue(controller.selectedContentViewControllerForTesting === controller.filesViewController)
    }

    func testFilesBrowserFillsStandalonePanelWhenNoEmbeddedEditorIsOpen() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Files.editorSplit"))

        let browserFrame = controller.fileBrowserPaneViewForTesting.convert(
            controller.fileBrowserPaneViewForTesting.bounds,
            to: controller.view
        )
        XCTAssertEqual(browserFrame.minX, 0, accuracy: 1)
        XCTAssertEqual(browserFrame.width, controller.view.bounds.width, accuracy: 1)

        let nameColumn = try XCTUnwrap(controller.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name")))
        XCTAssertGreaterThanOrEqual(nameColumn.width, 300)
    }

    func testFilesPanelShowsTransferProgressStripAtBottom() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 0,
                        bytesTotal: 2_048,
                        rawStatus: "running",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )

        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 1_024,
                        bytesTotal: 2_048,
                        rawStatus: "running",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 101)
            )
        )

        let progress = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferProgress") as? NSProgressIndicator
        )
        let label = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )

        XCTAssertFalse(progress.isHidden)
        XCTAssertEqual(progress.doubleValue, 50, accuracy: 0.1)
        XCTAssertTrue(label.stringValue.contains("上传 release"))
        XCTAssertTrue(label.stringValue.contains("50%"))
        XCTAssertTrue(label.stringValue.contains("1 KB/s"))
        XCTAssertTrue(label.stringValue.contains("剩余 1 秒"))
    }

    func testFilesPanelShowsTransferControlButtonsInBottomStrip() throws {
        let controller = FilesViewController()
        controller.loadView()
        var actions: [(TransferQueueAction, String)] = []
        controller.onTransferStatusAction = { action, jobID in
            actions.append((action, jobID))
        }

        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 128,
                        bytesTotal: 2_048,
                        rawStatus: "running",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )

        let pauseButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let stopButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction") as? NSButton
        )

        XCTAssertFalse(pauseButton.isHidden)
        XCTAssertFalse(stopButton.isHidden)
        XCTAssertEqual(pauseButton.accessibilityLabel(), "暂停")
        XCTAssertEqual(stopButton.accessibilityLabel(), "停止")
        XCTAssertTrue(pauseButton.isEnabled)
        XCTAssertTrue(stopButton.isEnabled)

        pauseButton.performClick(nil as Any?)
        stopButton.performClick(nil as Any?)

        XCTAssertEqual(actions.map(\.0), [.pause, .stop])
        XCTAssertEqual(actions.map(\.1), ["upload_release", "upload_release"])
    }

    func testFilesPanelTransferControlButtonsFollowPausedAndStoppedStates() throws {
        let controller = FilesViewController()
        controller.loadView()

        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 512,
                        bytesTotal: 2_048,
                        rawStatus: "paused",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )

        let primaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let secondaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction") as? NSButton
        )

        XCTAssertEqual(primaryButton.accessibilityLabel(), "恢复")
        XCTAssertEqual(secondaryButton.accessibilityLabel(), "停止")
        XCTAssertTrue(primaryButton.isEnabled)
        XCTAssertTrue(secondaryButton.isEnabled)

        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 512,
                        bytesTotal: 2_048,
                        rawStatus: "stopped",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 101)
            )
        )

        XCTAssertEqual(secondaryButton.accessibilityLabel(), "重试")
        XCTAssertNil(primaryButton.accessibilityLabel())
        XCTAssertTrue(primaryButton.isHidden)
        XCTAssertFalse(primaryButton.isEnabled)
        XCTAssertFalse(secondaryButton.isHidden)
        XCTAssertTrue(secondaryButton.isEnabled)
    }

    func testFilesPanelStoppedTransferShowsSingleRetryButtonAndSendsRetryAction() throws {
        let controller = FilesViewController()
        controller.loadView()
        var actions: [(TransferQueueAction, String)] = []
        controller.onTransferStatusAction = { action, jobID in
            actions.append((action, jobID))
        }

        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 512,
                        bytesTotal: 2_048,
                        rawStatus: "stopped",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 101)
            )
        )

        let primaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let secondaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction") as? NSButton
        )

        XCTAssertTrue(primaryButton.isHidden)
        XCTAssertFalse(primaryButton.isEnabled)
        XCTAssertFalse(secondaryButton.isHidden)
        XCTAssertTrue(secondaryButton.isEnabled)
        XCTAssertEqual(secondaryButton.accessibilityLabel(), "重试")

        secondaryButton.performClick(nil as Any?)

        XCTAssertEqual(actions.map(\.0), [.retry])
        XCTAssertEqual(actions.map(\.1), ["upload_release"])
    }

    func testFilesPanelTransferControlsFitCompactBottomStrip() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_compact",
                        direction: .upload,
                        sourcePath: "/Users/alice/very-long-release-artifact-name.tar.gz",
                        destinationPath: "~/very-long-release-artifact-name.tar.gz",
                        bytesDone: 512,
                        bytesTotal: 2_048,
                        rawStatus: "running",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )
        controller.view.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )
        let progress = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferProgress") as? NSProgressIndicator
        )
        let primaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let secondaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction") as? NSButton
        )

        let labelFrame = label.convert(label.bounds, to: controller.view)
        let progressFrame = progress.convert(progress.bounds, to: controller.view)
        let primaryFrame = primaryButton.convert(primaryButton.bounds, to: controller.view)
        let secondaryFrame = secondaryButton.convert(secondaryButton.bounds, to: controller.view)

        XCTAssertLessThan(labelFrame.maxX, primaryFrame.minX)
        XCTAssertLessThan(progressFrame.maxX, primaryFrame.minX)
        XCTAssertLessThan(primaryFrame.maxX, secondaryFrame.minX)
        XCTAssertLessThanOrEqual(secondaryFrame.maxX, controller.view.bounds.maxX - 8)
    }

    func testFilesPanelKeepsCompletedTransferProgressStripVisible() throws {
        let controller = FilesViewController()
        controller.loadView()

        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 100,
                        bytesTotal: 100,
                        rawStatus: "completed",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 102)
            )
        )

        let progress = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferProgress") as? NSProgressIndicator
        )
        let label = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )

        XCTAssertFalse(progress.isHidden)
        XCTAssertEqual(progress.doubleValue, 100, accuracy: 0.1)
        XCTAssertTrue(label.stringValue.contains("上传 release"))
        XCTAssertTrue(label.stringValue.contains("100%"))
        XCTAssertTrue(label.stringValue.contains("已完成"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("已完成"))

        let primaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let secondaryButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction") as? NSButton
        )
        XCTAssertTrue(primaryButton.isHidden)
        XCTAssertTrue(secondaryButton.isHidden)
        XCTAssertFalse(primaryButton.isEnabled)
        XCTAssertFalse(secondaryButton.isEnabled)
    }

    func testFilesPanelShowsRemoteEditSyncStatusInBottomStrip() throws {
        let controller = FilesViewController()
        controller.loadView()

        controller.setRemoteEditSyncStatus(
            message: "Remote Edit：2 个本地编辑副本已加入上传队列",
            progressValue: 100
        )

        let progress = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferProgress") as? NSProgressIndicator
        )
        let label = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )

        XCTAssertFalse(progress.isHidden)
        XCTAssertEqual(progress.doubleValue, 100, accuracy: 0.1)
        XCTAssertEqual(label.stringValue, "Remote Edit：2 个本地编辑副本已加入上传队列")
        XCTAssertTrue(controller.visibleTextSnapshot.contains("Remote Edit"))
    }

    func testFilesPanelKeepsTransferRowsAndActionsWhenShowingOrdinaryStatus() throws {
        let controller = FilesViewController()
        controller.loadView()
        var actions: [(TransferQueueAction, String)] = []
        controller.onTransferStatusAction = { actions.append(($0, $1)) }
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "upload_release",
                direction: .upload,
                sourcePath: "/Users/alice/release.tar",
                destinationPath: "/srv/release.tar",
                bytesDone: 25,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            ),
            TransferQueueSnapshot.Row(
                jobID: "download_backup",
                direction: .download,
                sourcePath: "/srv/backup.tar",
                destinationPath: "/Users/alice/backup.tar",
                bytesDone: 50,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            )
        ]))

        controller.setRemoteEditSyncStatus(
            message: "Remote Edit：本地副本已加入上传队列",
            progressValue: 100
        )

        let transferLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )
        let secondTransferLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.1") as? NSTextField
        )
        let supplementalLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.2") as? NSTextField
        )
        let pause = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let secondStop = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction.1") as? NSButton
        )
        XCTAssertTrue(transferLabel.stringValue.contains("上传 release.tar"))
        XCTAssertTrue(secondTransferLabel.stringValue.contains("下载 backup.tar"))
        XCTAssertEqual(supplementalLabel.stringValue, "Remote Edit：本地副本已加入上传队列")

        pause.performClick(nil as Any?)
        secondStop.performClick(nil as Any?)

        XCTAssertEqual(actions.map(\.0), [.pause, .stop])
        XCTAssertEqual(actions.map(\.1), ["upload_release", "download_backup"])
    }

    func testFilesPanelUpdatesAndClearsOrdinaryStatusWithoutRemovingTransferRows() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "download_backup",
                direction: .download,
                sourcePath: "/srv/backup.tar",
                destinationPath: "/Users/alice/backup.tar",
                bytesDone: 50,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            )
        ]))
        controller.setRemoteEditSyncStatus(message: "正在刷新目录", progressValue: 10)

        controller.setRemoteEditSyncStatus(message: "目录刷新完成", progressValue: 100)

        let updatedStatus = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.1") as? NSTextField
        )
        XCTAssertEqual(updatedStatus.stringValue, "目录刷新完成")
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.2"))

        controller.setRemoteEditSyncStatus(message: "   ", progressValue: nil)

        let transferLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )
        XCTAssertTrue(transferLabel.stringValue.contains("下载 backup.tar"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.1"))
    }

    func testFilesPanelRefreshesTransferSnapshotAndClearsStaleOrdinaryStatus() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "upload_release",
                direction: .upload,
                sourcePath: "/Users/alice/release.tar",
                destinationPath: "/srv/release.tar",
                bytesDone: 25,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            ),
            TransferQueueSnapshot.Row(
                jobID: "download_backup",
                direction: .download,
                sourcePath: "/srv/backup.tar",
                destinationPath: "/Users/alice/backup.tar",
                bytesDone: 25,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            )
        ]))
        controller.setRemoteEditSyncStatus(message: "正在跟随终端目录", progressValue: 20)

        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "upload_release",
                direction: .upload,
                sourcePath: "/Users/alice/release.tar",
                destinationPath: "/srv/release.tar",
                bytesDone: 75,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            ),
            TransferQueueSnapshot.Row(
                jobID: "download_backup",
                direction: .download,
                sourcePath: "/srv/backup.tar",
                destinationPath: "/Users/alice/backup.tar",
                bytesDone: 50,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            )
        ]))

        let firstTransfer = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )
        let secondTransfer = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.1") as? NSTextField
        )
        XCTAssertTrue(firstTransfer.stringValue.contains("75%"))
        XCTAssertTrue(secondTransfer.stringValue.contains("下载 backup.tar"))
        XCTAssertTrue(secondTransfer.stringValue.contains("50%"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.2"))
        XCTAssertFalse(controller.visibleTextSnapshot.contains("正在跟随终端目录"))
    }

    func testFilesPanelShowsEveryRunningTransferWhenAnotherTaskStarts() throws {
        let controller = FilesViewController()
        controller.loadView()

        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 70,
                        bytesTotal: 100,
                        rawStatus: "running",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        )
        controller.setTransferStatusSnapshot(
            TransferQueueSnapshot(
                rows: [
                    TransferQueueSnapshot.Row(
                        jobID: "upload_release",
                        direction: .upload,
                        sourcePath: "/Users/alice/release",
                        destinationPath: "~/release",
                        bytesDone: 80,
                        bytesTotal: 100,
                        rawStatus: "running",
                        diagnostic: nil
                    ),
                    TransferQueueSnapshot.Row(
                        jobID: "download_swap",
                        direction: .download,
                        sourcePath: "/srv/swap.img",
                        destinationPath: "/Users/alice/swap.img",
                        bytesDone: 50,
                        bytesTotal: 100,
                        rawStatus: "running",
                        diagnostic: nil
                    )
                ],
                capturedAt: Date(timeIntervalSince1970: 101)
            )
        )

        let firstProgress = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferProgress") as? NSProgressIndicator
        )
        let firstLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )
        let secondProgress = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferProgress.1") as? NSProgressIndicator
        )
        let secondLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.1") as? NSTextField
        )

        XCTAssertEqual(firstProgress.doubleValue, 80, accuracy: 0.1)
        XCTAssertEqual(secondProgress.doubleValue, 50, accuracy: 0.1)
        XCTAssertTrue(firstLabel.stringValue.contains("上传 release"))
        XCTAssertTrue(firstLabel.stringValue.contains("80%"))
        XCTAssertTrue(secondLabel.stringValue.contains("下载 swap.img"))
        XCTAssertTrue(secondLabel.stringValue.contains("50%"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("上传 release"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("下载 swap.img"))
    }

    func testFilesPanelMultiTransferRowsDispatchActionsToTheirOwnJobs() throws {
        let controller = FilesViewController()
        controller.loadView()
        var actions: [(TransferQueueAction, String)] = []
        controller.onTransferStatusAction = { actions.append(($0, $1)) }
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "upload_release",
                direction: .upload,
                sourcePath: "/Users/alice/release.tar",
                destinationPath: "/srv/release.tar",
                bytesDone: 25,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            ),
            TransferQueueSnapshot.Row(
                jobID: "download_backup",
                direction: .download,
                sourcePath: "/srv/backup.tar",
                destinationPath: "/Users/alice/backup.tar",
                bytesDone: 50,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            )
        ]))

        let firstPause = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let secondStop = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction.1") as? NSButton
        )
        firstPause.performClick(nil as Any?)
        secondStop.performClick(nil as Any?)

        XCTAssertEqual(actions.map(\.0), [.pause, .stop])
        XCTAssertEqual(actions.map(\.1), ["upload_release", "download_backup"])
    }

    func testFilesPanelKeepsResumingTransferVisibleAndControllable() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: [
            TransferQueueSnapshot.Row(
                jobID: "upload_resume",
                direction: .upload,
                sourcePath: "/Users/alice/release.tar",
                destinationPath: "/srv/release.tar",
                bytesDone: 50,
                bytesTotal: 100,
                rawStatus: "resuming",
                diagnostic: nil
            )
        ]))

        let label = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )
        let pause = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferPrimaryAction") as? NSButton
        )
        let stop = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferSecondaryAction") as? NSButton
        )
        XCTAssertTrue(label.stringValue.contains("续传中"))
        XCTAssertEqual(pause.accessibilityLabel(), "暂停")
        XCTAssertEqual(stop.accessibilityLabel(), "停止")
    }

    func testFilesPanelMakesLongTransferListScrollableWithoutDroppingRows() throws {
        let controller = FilesViewController()
        controller.loadView()
        let rows = (0 ..< 5).map { index in
            TransferQueueSnapshot.Row(
                jobID: "job_\(index)",
                direction: .upload,
                sourcePath: "/Users/alice/file-\(index).tar",
                destinationPath: "/srv/file-\(index).tar",
                bytesDone: UInt64(index * 10),
                bytesTotal: 100,
                rawStatus: index < 2 ? "running" : "queued",
                diagnostic: nil
            )
        }
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: rows))

        let scrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatusList") as? NSScrollView
        )
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatusRow.4"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("file-0.tar"))
        XCTAssertTrue(controller.visibleTextSnapshot.contains("file-4.tar"))
    }

    func testFilesPanelKeepsTransferListScrollPositionDuringProgressRefresh() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 420)
        let rows = (0 ..< 6).map { index in
            TransferQueueSnapshot.Row(
                jobID: "job_\(index)",
                direction: .upload,
                sourcePath: "/Users/alice/file-\(index).tar",
                destinationPath: "/srv/file-\(index).tar",
                bytesDone: UInt64(index * 10),
                bytesTotal: 100,
                rawStatus: index < 2 ? "running" : "queued",
                diagnostic: nil
            )
        }
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: rows))
        controller.view.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatusList") as? NSScrollView
        )
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 40))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let scrolledY = scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolledY, 0)

        let refreshedRows = rows.map { row in
            TransferQueueSnapshot.Row(
                jobID: row.jobID,
                direction: row.direction,
                sourcePath: row.sourcePath,
                destinationPath: row.destinationPath,
                bytesDone: min(row.bytesDone + 5, row.bytesTotal),
                bytesTotal: row.bytesTotal,
                rawStatus: row.rawStatus,
                diagnostic: row.diagnostic
            )
        }
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: refreshedRows))
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(scrollView.contentView.bounds.origin.y, scrolledY, accuracy: 1)
    }

    func testFilesPanelReindexesReusedTransferRowsAfterFirstTaskDisappears() throws {
        let controller = FilesViewController()
        controller.loadView()
        let initialRows = ["job_a", "job_b"].map { jobID in
            TransferQueueSnapshot.Row(
                jobID: jobID,
                direction: .upload,
                sourcePath: "/Users/alice/\(jobID).tar",
                destinationPath: "/srv/\(jobID).tar",
                bytesDone: 10,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            )
        }
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: initialRows))
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: [initialRows[1]]))

        let firstLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus") as? NSTextField
        )
        XCTAssertTrue(firstLabel.stringValue.contains("job_b.tar"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatus.1"))
    }

    func testFilesPanelShrinksTransferListBeforeCollapsingRemoteFileTable() throws {
        let controller = FilesViewController()
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 260)
        let rows = (0 ..< 5).map { index in
            TransferQueueSnapshot.Row(
                jobID: "job_compact_\(index)",
                direction: .download,
                sourcePath: "/srv/file-\(index).tar",
                destinationPath: "/Users/alice/file-\(index).tar",
                bytesDone: 10,
                bytesTotal: 100,
                rawStatus: "running",
                diagnostic: nil
            )
        }
        controller.setTransferStatusSnapshot(TransferQueueSnapshot(rows: rows))
        controller.view.layoutSubtreeIfNeeded()

        let transferScrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Files.transferStatusList") as? NSScrollView
        )
        let remoteScrollView = try XCTUnwrap(controller.tableView.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(remoteScrollView.frame.height, 43)
        XCTAssertTrue(transferScrollView.hasVerticalScroller)
    }

    func testInspectorFilesCoordinatorUsesEmbeddedStacioEditorOpener() {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())
        controller.loadView()

        XCTAssertTrue(controller.filesCoordinatorForTesting.remoteEditOpenerForTesting is EmbeddedRemoteEditOpener)
    }

    func testInspectorEditorAIButtonPrefillsAssistantWithRemoteFileQuestion() throws {
        let aiPanel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: RuleBasedAIAssistantProvider(),
                executionCoordinator: UnavailableAgentCommandExecutorForFilesTests()
            ),
            contextProvider: { nil }
        )
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            aiAssistantViewController: aiPanel
        )
        controller.loadView()
        controller.filesViewController?.presentEmbeddedRemoteDocument(
            RemoteTextEditorDocumentDescriptor(
                remotePath: "/etc/nginx/nginx.conf",
                fileName: "nginx.conf",
                content: "server { listen 80; }\n",
                byteCount: 24
            )
        )
        controller.view.layoutSubtreeIfNeeded()

        let aiButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorAskAI") as? NSButton
        )
        aiButton.performClick(nil as Any?)

        XCTAssertEqual(controller.selectedTabLabel, L10n.AI.title)
        XCTAssertTrue(aiPanel.questionTextForTesting.contains("nginx.conf"))
        XCTAssertTrue(aiPanel.questionTextForTesting.contains("/etc/nginx/nginx.conf"))
        XCTAssertTrue(aiPanel.questionTextForTesting.contains("listen 80"))
    }

    func testInspectorEditorActionRowIsHiddenUntilEditorOpensAndAfterEditorCloses() throws {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())
        controller.loadView()
        let actionRow = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorActions") as? NSStackView
        )
        let closeButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorClose") as? NSButton
        )
        let collapseButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorCollapse") as? NSButton
        )
        let backupButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorBackup") as? NSButton
        )
        let restoreButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorRestore") as? NSButton
        )
        let fileURL = try makeTemporaryEditorFile(name: "service.conf", contents: "enabled=true\n")

        XCTAssertTrue(actionRow.isHidden)

        controller.filesViewController?.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(actionRow.isHidden)
        XCTAssertFalse(closeButton.isHidden)
        XCTAssertFalse(collapseButton.isHidden)
        XCTAssertFalse(backupButton.isHidden)
        XCTAssertFalse(restoreButton.isHidden)
        XCTAssertEqual(collapseButton.toolTip, "收起编辑器")

        closeButton.performClick(nil as Any?)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(actionRow.isHidden)
    }

    func testInspectorEditorActionRowShowsOnlyExpandButtonWhenEditorIsCollapsed() throws {
        let controller = InspectorViewController(transferHistoryStore: NoOpSCPTransferHistoryStore())
        controller.loadView()
        let actionRow = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorActions") as? NSStackView
        )
        let closeButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorClose") as? NSButton
        )
        let collapseButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorCollapse") as? NSButton
        )
        let backupButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorBackup") as? NSButton
        )
        let restoreButton = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Inspector.editorRestore") as? NSButton
        )
        let fileURL = try makeTemporaryEditorFile(name: "service.conf", contents: "enabled=true\n")

        controller.filesViewController?.presentEmbeddedEditor(localURL: fileURL, saveHandler: nil)
        controller.view.layoutSubtreeIfNeeded()
        collapseButton.performClick(nil as Any?)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(actionRow.isHidden)
        XCTAssertTrue(closeButton.isHidden)
        XCTAssertFalse(collapseButton.isHidden)
        XCTAssertTrue(backupButton.isHidden)
        XCTAssertTrue(restoreButton.isHidden)
        XCTAssertEqual(collapseButton.toolTip, "展开编辑器")

        collapseButton.performClick(nil as Any?)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(actionRow.isHidden)
        XCTAssertFalse(closeButton.isHidden)
        XCTAssertFalse(collapseButton.isHidden)
        XCTAssertFalse(backupButton.isHidden)
        XCTAssertFalse(restoreButton.isHidden)
        XCTAssertEqual(collapseButton.toolTip, "收起编辑器")
    }

    func testInspectorPassesLiveSessionContextProviderToFilesCoordinator() throws {
        let bridge = RecordingInspectorRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/home/deploy/app.log", size: 64, linkTarget: nil)
        ])
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: {
                TunnelLiveSessionContext(
                    config: SshConnectionConfig(
                        host: "example.com",
                        port: 22,
                        username: "deploy",
                        authMethod: .agent,
                        connectTimeoutMs: 10_000
                    ),
                    secret: .agent,
                    expectedFingerprintSHA256: "SHA256:test"
                )
            },
            remoteFilesBridge: bridge
        )
        controller.loadView()

        let entries = try controller.filesCoordinatorForTesting.loadCurrentLiveDirectory(remotePath: "/home/deploy")

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(bridge.liveHosts, ["example.com"])
        XCTAssertEqual(controller.filesViewController?.entryCount, 1)
    }

    func testInspectorSelectingFilesTabLoadsCurrentLiveDirectory() throws {
        let bridge = RecordingInspectorRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/current.log", size: 64, linkTarget: nil)
        ])
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "current.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:current"
        )
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { context },
            remoteFilesBridge: bridge
        )

        controller.loadView()
        try controller.selectFilesTabAndLoadCurrentDirectory(
            binding: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term_current",
                context: context,
                remotePath: "/srv/app"
            )
        )
        controller.selectSectionForTesting(1)
        controller.selectSectionForTesting(0)

        XCTAssertTrue(waitUntil { controller.filesViewController?.entryCount == 1 })
        XCTAssertEqual(bridge.liveHosts, ["current.example.com", "current.example.com"])
        XCTAssertEqual(bridge.liveRemotePaths, ["/srv/app", "/srv/app"])
        XCTAssertEqual(controller.filesViewController?.entryCount, 1)
    }

    func testInspectorDirectoryFollowFailureKeepsLastGoodDirectoryWithoutModalError() throws {
        let bridge = PathSensitiveInspectorRemoteFilesBridge(entriesByPath: [
            "/home/FengLee": [
                RemoteFileEntry(kind: .file, path: "/home/FengLee/logs", size: 64, linkTarget: nil)
            ],
            "/opt/containerd": [
                RemoteFileEntry(kind: .file, path: "/opt/containerd/config.toml", size: 96, linkTarget: nil)
            ]
        ])
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "follow.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:follow"
        )
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { context },
            remoteFilesBridge: bridge
        )

        controller.loadView()
        try controller.selectFilesTabAndLoadCurrentDirectory(
            binding: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term-follow",
                context: context,
                remotePath: "/home/FengLee"
            )
        )
        XCTAssertTrue(waitUntil { controller.filesViewController?.containsRemoteEntry(named: "logs") == true })

        controller.followRemoteTerminalDirectoryIfEnabled(runtimeID: "term-follow", remotePath: "/does/not/exist")

        XCTAssertTrue(waitUntil { bridge.liveRemotePaths.contains("/does/not/exist") })
        XCTAssertTrue(waitUntil { controller.filesViewController?.currentRemotePath == "/home/FengLee" })
        XCTAssertEqual(controller.filesViewController?.currentRemotePath, "/home/FengLee")
        XCTAssertTrue(controller.filesViewController?.containsRemoteEntry(named: "logs") == true)
        XCTAssertFalse(controller.filesViewController?.visibleTextSnapshot.contains("无法刷新远端目录") == true)

        controller.followRemoteTerminalDirectoryIfEnabled(runtimeID: "term-follow", remotePath: "/opt/containerd")

        XCTAssertTrue(waitUntil { controller.filesViewController?.containsRemoteEntry(named: "config.toml") == true })
        XCTAssertEqual(controller.filesViewController?.currentRemotePath, "/opt/containerd")
        XCTAssertEqual(bridge.liveRemotePaths, ["/home/FengLee", "/does/not/exist", "/opt/containerd"])
    }

    func testInspectorDirectoryFollowFailureKeepsLastGoodDirectoryEvenWhenTargetHasStaleCache() throws {
        let bridge = PathSensitiveInspectorRemoteFilesBridge(entriesByPath: [
            "/stale": [
                RemoteFileEntry(kind: .file, path: "/stale/old.log", size: 64, linkTarget: nil)
            ],
            "/home/FengLee": [
                RemoteFileEntry(kind: .file, path: "/home/FengLee/logs", size: 64, linkTarget: nil)
            ]
        ])
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "follow.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:follow"
        )
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { context },
            remoteFilesBridge: bridge
        )

        controller.loadView()
        try controller.selectFilesTabAndLoadCurrentDirectory(
            binding: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term-follow",
                context: context,
                remotePath: "/stale"
            )
        )
        XCTAssertTrue(waitUntil { controller.filesViewController?.containsRemoteEntry(named: "old.log") == true })
        try controller.selectFilesTabAndLoadCurrentDirectory(
            binding: InspectorViewController.RemoteFilesBinding(
                runtimeID: "term-follow",
                context: context,
                remotePath: "/home/FengLee"
            )
        )
        XCTAssertTrue(waitUntil { controller.filesViewController?.containsRemoteEntry(named: "logs") == true })

        bridge.setFailingRemotePaths(["/stale"])
        controller.followRemoteTerminalDirectoryIfEnabled(runtimeID: "term-follow", remotePath: "/stale")

        XCTAssertTrue(waitUntil { bridge.liveRemotePaths == ["/stale", "/home/FengLee", "/stale"] })
        XCTAssertTrue(waitUntil { controller.filesViewController?.currentRemotePath == "/home/FengLee" })
        XCTAssertEqual(controller.filesViewController?.currentRemotePath, "/home/FengLee")
        XCTAssertTrue(controller.filesViewController?.containsRemoteEntry(named: "logs") == true)
        XCTAssertFalse(controller.filesViewController?.containsRemoteEntry(named: "old.log") == true)
        XCTAssertFalse(controller.filesViewController?.visibleTextSnapshot.contains("无法刷新远端目录") == true)
    }

    func testInspectorDisconnectRuntimeCleansFilesEditorCacheAndTransfersWithoutTouchingOtherRuntime() throws {
        let bridge = RecordingInspectorRemoteFilesBridge(entries: [
            RemoteFileEntry(kind: .file, path: "/srv/app/current.log", size: 64, linkTarget: nil)
        ])
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "target.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:target"
        )
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { context },
            remoteFilesBridge: bridge
        )
        controller.loadView()
        try controller.selectFilesTabAndLoadCurrentDirectory(
            binding: InspectorViewController.RemoteFilesBinding(
                runtimeID: "runtime-target",
                context: context,
                remotePath: "/srv/app"
            )
        )
        let targetLocalURL = try makeTemporaryEditorFile(name: "target.conf", contents: "enabled=false\n")
        let otherLocalURL = try makeTemporaryEditorFile(name: "other.conf", contents: "enabled=false\n")
        controller.filesViewController?.presentEmbeddedEditor(
            localURL: targetLocalURL,
            saveHandler: nil,
            closeConfirmer: FilesViewControllerRecordingRemoteTextEditorCloseConfirmer(decision: .discard)
        )
        controller.filesViewController?.embeddedEditorViewControllerForTesting?.replaceTextForTesting("enabled=true\n")
        try controller.filesCoordinatorForTesting.registerRemoteEditCacheItemForTesting(
            remotePath: "/srv/app/target.conf",
            localURL: targetLocalURL,
            runtimeID: "runtime-target",
            sessionID: "runtime-target"
        )
        try controller.filesCoordinatorForTesting.registerRemoteEditCacheItemForTesting(
            remotePath: "/srv/app/other.conf",
            localURL: otherLocalURL,
            runtimeID: "runtime-other",
            sessionID: "runtime-other"
        )
        let targetJob = ScpTransferJob(
            id: "target-transfer",
            direction: .upload,
            sourcePath: targetLocalURL.path,
            destinationPath: "/srv/app/target.conf",
            bytesTotal: 14
        )
        let otherJob = ScpTransferJob(
            id: "other-transfer",
            direction: .upload,
            sourcePath: otherLocalURL.path,
            destinationPath: "/srv/app/other.conf",
            bytesTotal: 14
        )
        controller.transferQueueCoordinator?.enqueueTransfer(runtimeID: "runtime-target", job: targetJob)
        controller.transferQueueCoordinator?.enqueueTransfer(runtimeID: "runtime-other", job: otherJob)

        controller.disconnectFilesBindingIfNeeded(runtimeID: "runtime-target")

        XCTAssertNil(controller.filesViewController?.embeddedEditorViewControllerForTesting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetLocalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherLocalURL.path))
        XCTAssertEqual(controller.transferQueueViewController?.snapshotForTesting.rows.map(\.jobID), ["other-transfer"])
        XCTAssertTrue(controller.filesViewController?.visibleTextSnapshot.contains("文件连接已断开") == true)

        controller.disconnectFilesBindingIfNeeded(runtimeID: "runtime-target")

        XCTAssertEqual(controller.transferQueueViewController?.snapshotForTesting.rows.map(\.jobID), ["other-transfer"])
    }

    func testDisconnectFilesBindingReturnsFalseAndKeepsBindingWhenEmbeddedEditorCloseIsCanceled() throws {
        let bridge = RecordingInspectorRemoteFilesBridge(entries: [])
        let context = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "target.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:target"
        )
        let binding = InspectorViewController.RemoteFilesBinding(
            runtimeID: "runtime-target",
            context: context,
            remotePath: "/srv/app"
        )
        let controller = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            tunnelLiveSessionContextProvider: { context },
            remoteFilesBridge: bridge
        )
        controller.loadView()
        try controller.selectFilesTabAndLoadCurrentDirectory(binding: binding)
        let targetLocalURL = try makeTemporaryEditorFile(name: "target.conf", contents: "enabled=false\n")
        defer { try? FileManager.default.removeItem(at: targetLocalURL) }
        controller.filesViewController?.presentEmbeddedEditor(
            localURL: targetLocalURL,
            saveHandler: nil as RemoteEditSaveHandler?,
            closeConfirmer: FilesViewControllerRecordingRemoteTextEditorCloseConfirmer(decision: .cancel)
        )
        controller.filesViewController?.embeddedEditorViewControllerForTesting?.replaceTextForTesting("enabled=true\n")

        let didDisconnect = controller.disconnectFilesBindingIfNeeded(runtimeID: "runtime-target")

        XCTAssertFalse(didDisconnect)
        XCTAssertTrue(controller.isFilesTabBound(to: binding))
        XCTAssertNotNil(controller.filesViewController?.embeddedEditorViewControllerForTesting)
        XCTAssertFalse(controller.filesViewController?.visibleTextSnapshot.contains("文件连接已断开") == true)
    }
}

private final class RecordingInspectorRemoteFilesBridge: RemoteFilesBridging {
    var liveHosts: [String] = []
    var liveRemotePaths: [String] = []
    private let entries: [RemoteFileEntry]

    init(entries: [RemoteFileEntry]) {
        self.entries = entries
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        entries
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        liveHosts.append(config.host)
        liveRemotePaths.append(remotePath)
        return entries
    }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {}

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private final class PathSensitiveInspectorRemoteFilesBridge: RemoteFilesBridging {
    private let recordingQueue = DispatchQueue(label: "Stacio.Tests.PathSensitiveInspectorRemoteFilesBridge")
    private var recordedLiveRemotePaths: [String] = []
    private var failingRemotePaths: Set<String> = []
    private let entriesByPath: [String: [RemoteFileEntry]]

    init(entriesByPath: [String: [RemoteFileEntry]]) {
        self.entriesByPath = entriesByPath
    }

    var liveRemotePaths: [String] {
        recordingQueue.sync { recordedLiveRemotePaths }
    }

    func setFailingRemotePaths(_ paths: Set<String>) {
        recordingQueue.sync {
            failingRemotePaths = paths
        }
    }

    func parseRemoteListing(_ input: String) throws -> [RemoteFileEntry] {
        []
    }

    func listLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws -> [RemoteFileEntry] {
        let shouldFail = recordingQueue.sync { () -> Bool in
            recordedLiveRemotePaths.append(remotePath)
            return failingRemotePaths.contains(remotePath)
        }
        if shouldFail {
            throw FilesError.UnsafePath
        }
        guard let entries = entriesByPath[remotePath] else {
            throw FilesError.UnsafePath
        }
        return entries
    }

    func createLiveRemoteDirectory(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String
    ) throws {}

    func renameLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        fromPath: String,
        toPath: String
    ) throws {}

    func deleteLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        recursive: Bool
    ) throws {}

    func chmodLiveRemotePath(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        remotePath: String,
        mode: String
    ) throws {}
}

private extension InspectorViewController {
    var filesCoordinatorForTesting: FilesCoordinator {
        let mirror = Mirror(reflecting: self)
        return mirror.children.first { $0.label == "filesCoordinator" }?.value as! FilesCoordinator
    }

}

private extension FilesCoordinator {
    var remoteEditOpenerForTesting: RemoteEditOpening {
        let mirror = Mirror(reflecting: self)
        return mirror.children.first { $0.label == "remoteEditOpener" }?.value as! RemoteEditOpening
    }
}

private func makeTemporaryEditorFile(name: String, contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StacioFilesEditorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent(name)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

private func makeTemporaryEditorFile(name: String, data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StacioFilesEditorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent(name)
    try data.write(to: fileURL)
    return fileURL
}

private final class RecordingFilesEditorCloseConfirmer: RemoteTextEditorCloseConfirming {
    let decision: RemoteTextEditorCloseDecision
    private(set) var promptedFileNames: [String] = []

    init(decision: RemoteTextEditorCloseDecision) {
        self.decision = decision
    }

    func confirmClose(fileName: String, parentWindow: NSWindow?) -> RemoteTextEditorCloseDecision {
        promptedFileNames.append(fileName)
        return decision
    }
}

@MainActor
private struct UnavailableAgentCommandExecutorForFilesTests: AgentCommandExecuting {
    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        throw AgentExecutionError.terminalNotFound
    }
}

@MainActor
private func assertFilesActionState(
    _ controller: FilesViewController,
    refreshButton: NSButton,
    uploadButton: NSButton,
    downloadButton: NSButton,
    moreButton: NSButton,
    canDownload: Bool,
    canRename: Bool,
    canDelete: Bool,
    canChmod: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(refreshButton.isEnabled, file: file, line: line)
    XCTAssertTrue(uploadButton.isEnabled, file: file, line: line)
    XCTAssertTrue(moreButton.isEnabled, file: file, line: line)
    XCTAssertTrue(menuItemEnabled(controller, title: "新建远端目录"), file: file, line: line)
    XCTAssertEqual(downloadButton.isEnabled, canDownload, file: file, line: line)
    XCTAssertEqual(menuItemEnabled(controller, title: "重命名远端项目"), canRename, file: file, line: line)
    XCTAssertEqual(menuItemEnabled(controller, title: "删除远端项目"), canDelete, file: file, line: line)
    XCTAssertEqual(menuItemEnabled(controller, title: "修改远端权限"), canChmod, file: file, line: line)
}

@MainActor
private func menuItemEnabled(_ controller: FilesViewController, title: String) -> Bool {
    let mirror = Mirror(reflecting: controller)
    let menu = mirror.children.first { $0.label == "moreMenu" }?.value as? NSMenu
    return menu?.items.first { $0.title == title }?.isEnabled ?? false
}

@MainActor
private func openEntry(
    named name: String,
    controller: FilesViewController,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for row in 0..<controller.tableView.numberOfRows where controller.tableView.viewText(atColumn: 0, row: row) == name {
        controller.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.openSelectedEntryForTesting()
        return
    }
    XCTFail("Missing remote file row named \(name)", file: file, line: line)
}

private func performControlBShortcut(on view: NSView) -> Bool {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .control,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "b",
        charactersIgnoringModifiers: "b",
        isARepeat: false,
        keyCode: 11
    ) else {
        return false
    }
    return view.performKeyEquivalent(with: event)
}

private func performEscapeShortcut(on view: NSView) -> Bool {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false,
        keyCode: 53
    ) else {
        return false
    }
    return view.performKeyEquivalent(with: event)
}

@MainActor
private final class FilesViewControllerRecordingRemoteTextEditorCloseConfirmer: RemoteTextEditorCloseConfirming {
    let decision: RemoteTextEditorCloseDecision
    private(set) var promptedFileNames: [String] = []

    init(decision: RemoteTextEditorCloseDecision) {
        self.decision = decision
    }

    func confirmClose(fileName: String, parentWindow: NSWindow?) -> RemoteTextEditorCloseDecision {
        promptedFileNames.append(fileName)
        return decision
    }
}

private extension NSTableView {
    func viewText(atColumn column: Int, row: Int) -> String? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.textField?.stringValue
    }

    func viewIconLabel(atColumn column: Int, row: Int) -> String? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.imageView?.accessibilityLabel()
    }

    func viewIconSize(atColumn column: Int, row: Int) -> NSSize? {
        let cell = view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
        return cell?.imageView?.image?.size
    }
}

private extension NSView {
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
