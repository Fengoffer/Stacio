import AppKit
import XCTest
import StacioCoreBindings
@testable import StacioApp

@MainActor
final class TerminalFavoriteCommandTests: XCTestCase {
    private func findView(_ identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for subview in root.subviews {
            if let match = findView(identifier, in: subview) { return match }
        }
        return nil
    }

    func testStorePersistsCRUDAndMigratesLegacyCommands() throws {
        let suiteName = "StacioFavoriteCommands-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["docker ps", "docker ps", "kubectl get pods"], forKey: "Stacio.Settings.favoriteCommands")

        let store = TerminalFavoriteCommandStore(defaults: defaults)
        XCTAssertEqual(store.commands.map(\.command), ["docker ps", "kubectl get pods"])

        let added = try XCTUnwrap(store.add(TerminalFavoriteCommand(name: "Logs", command: "journalctl -f", details: "追踪日志", tags: ["logs"])))
        XCTAssertTrue(store.setEnabled(false, id: added.id))
        XCTAssertFalse(store.commands.first(where: { $0.id == added.id })?.enabled ?? true)

        var edited = try XCTUnwrap(store.commands.first(where: { $0.id == added.id }))
        edited.details = "实时日志"
        XCTAssertTrue(store.update(edited))
        XCTAssertEqual(store.commands.first(where: { $0.id == added.id })?.details, "实时日志")
        edited.command = ""
        XCTAssertFalse(store.update(edited))
        XCTAssertTrue(store.remove(id: added.id))
        XCTAssertNil(store.commands.first(where: { $0.id == added.id }))

        let reloaded = TerminalFavoriteCommandStore(defaults: defaults)
        XCTAssertEqual(reloaded.commands.map(\.command), ["docker ps", "kubectl get pods"])
    }

    func testStoreRejectsCommandsWithControlCharacters() throws {
        let suiteName = "StacioFavoriteCommandsSafety-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TerminalFavoriteCommandStore(defaults: defaults)

        let unsafe = TerminalFavoriteCommand(name: "Unsafe", command: "echo ok\nrm -rf /")
        XCTAssertFalse(unsafe.isSafeForInsertion)
        XCTAssertNil(store.add(unsafe))

        let safe = try XCTUnwrap(store.add(TerminalFavoriteCommand(name: "Safe", command: "echo ok")))
        var edited = safe
        edited.command = "echo ok\rwhoami"
        XCTAssertFalse(store.update(edited))
        XCTAssertEqual(store.commands.first?.command, "echo ok")
    }

    func testOperatingSystemClassificationAndMatching() {
        func info(
            id: String,
            idLike: [String] = [],
            name: String = "",
            prettyName: String = "",
            kernelName: String = "Linux"
        ) -> RemoteOperatingSystemInfo {
            RemoteOperatingSystemInfo(
                id: id,
                idLike: idLike,
                name: name,
                prettyName: prettyName,
                version: "",
                versionId: "",
                kernelName: kernelName,
                kernelRelease: "",
                architecture: "x86_64"
            )
        }

        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "ubuntu")), .ubuntuDebian)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "rocky", idLike: ["rhel"])), .centOSRHEL)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "centos", idLike: ["rhel", "fedora"])), .centOSRHEL)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "fedora")), .fedora)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "alpine")), .alpine)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "darwin", name: "macOS")), .macOS)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "arch", name: "Arch Linux")), .archLinux)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "opensuse")), .openSUSE)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "freebsd")), .freeBSD)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "openeuler")), .openEuler)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "uos", name: "UnionTech OS Server")), .unionTechUOS)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "deepin")), .deepin)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "kylin")), .kylin)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "anolis")), .anolis)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "opencloudos")), .openCloudOS)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "alinux")), .alibabaCloudLinux)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "tencentos")), .tencentOS)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "windows", kernelName: "Windows_NT")), .windows)
        XCTAssertEqual(TerminalCommandOperatingSystem.classify(info(id: "mystery")), .unknown)

        let generic = TerminalFavoriteCommand(name: "List", command: "ls", operatingSystems: [.generic])
        let ubuntuOnly = TerminalFavoriteCommand(name: "Install", command: "apt install", operatingSystems: [.ubuntuDebian])
        XCTAssertTrue(TerminalCommandOperatingSystem.unknown.accepts(generic))
        XCTAssertFalse(TerminalCommandOperatingSystem.unknown.accepts(ubuntuOnly))
        XCTAssertTrue(TerminalCommandOperatingSystem.ubuntuDebian.accepts(ubuntuOnly))
    }

    func testOperatingSystemCatalogCoversCommonLocalAndRemoteTargets() {
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.macOS))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.windows))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.archLinux))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.openSUSE))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.freeBSD))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.openEuler))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.unionTechUOS))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.deepin))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.kylin))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.anolis))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.openCloudOS))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.alibabaCloudLinux))
        XCTAssertTrue(TerminalCommandOperatingSystem.allCases.contains(.tencentOS))
    }

    func testCustomOperatingSystemsPersistAndMatchRemoteIdentity() throws {
        let suiteName = "StacioFavoriteCustomOS-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TerminalFavoriteCommandStore(defaults: defaults)
        let favorite = try XCTUnwrap(store.add(TerminalFavoriteCommand(
            name: "Neo status",
            command: "neo-service status",
            operatingSystems: [],
            customOperatingSystems: ["Neo Linux"]
        )))

        XCTAssertFalse(TerminalCommandOperatingSystem.unknown.accepts(favorite))
        XCTAssertTrue(TerminalCommandOperatingSystem.unknown.accepts(
            favorite,
            operatingSystemIdentity: "neo linux server 12 x86_64"
        ))
        let suggestions = TerminalCommandCompletionEngine.suggestions(
            for: "neo-",
            favoriteCommands: [favorite],
            operatingSystem: .unknown,
            operatingSystemIdentity: "Neo Linux Server 12"
        )
        XCTAssertEqual(suggestions.first?.choices.first?.replacement, "neo-service status")
        XCTAssertTrue(suggestions.first?.detail.contains("Neo Linux") == true)

        let reloaded = TerminalFavoriteCommandStore(defaults: defaults)
        XCTAssertEqual(reloaded.commands.first?.customOperatingSystems, ["Neo Linux"])
        XCTAssertTrue(reloaded.commands.first?.operatingSystems.isEmpty == true)
    }

    func testFavoriteCommandDecodesLegacyPayloadWithoutCustomOperatingSystems() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id.uuidString,
            "name": "Legacy",
            "command": "uptime",
            "details": "",
            "tags": [],
            "operatingSystems": ["generic"],
            "enabled": true
        ])
        let decoded = try JSONDecoder().decode(TerminalFavoriteCommand.self, from: data)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.operatingSystems, [.generic])
        XCTAssertTrue(decoded.customOperatingSystems.isEmpty)
    }

    func testBuiltInCommandsAreFilteredByOperatingSystemAndShowSource() {
        let ubuntu = TerminalCommandCompletionEngine.suggestions(
            for: "ap",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .ubuntuDebian
        )
        XCTAssertEqual(ubuntu.first?.choices.first?.replacement, "apt")
        XCTAssertTrue(ubuntu.first?.detail.contains("内置命令") == true)
        XCTAssertTrue(ubuntu.first?.detail.contains("适用系统：Ubuntu / Debian") == true)

        let alpine = TerminalCommandCompletionEngine.suggestions(
            for: "ap",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .alpine
        )
        XCTAssertEqual(alpine.first?.choices.first?.replacement, "apk")

        let unknown = TerminalCommandCompletionEngine.suggestions(
            for: "dn",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .unknown
        )
        XCTAssertTrue(unknown.isEmpty)

        let unknownService = TerminalCommandCompletionEngine.suggestions(
            for: "sys",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .unknown
        )
        XCTAssertTrue(unknownService.isEmpty)

        let ubuntuService = TerminalCommandCompletionEngine.suggestions(
            for: "sys",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .ubuntuDebian
        )
        XCTAssertEqual(ubuntuService.first?.choices.first?.replacement, "systemctl")

        let macOS = TerminalCommandCompletionEngine.suggestions(
            for: "br",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .macOS
        )
        XCTAssertEqual(macOS.first?.choices.first?.replacement, "brew")

        let windows = TerminalCommandCompletionEngine.suggestions(
            for: "win",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .windows
        )
        XCTAssertEqual(windows.first?.choices.first?.replacement, "winget")

        let arch = TerminalCommandCompletionEngine.suggestions(
            for: "pac",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .archLinux
        )
        XCTAssertEqual(arch.first?.choices.first?.replacement, "pacman")

        let openEuler = TerminalCommandCompletionEngine.suggestions(
            for: "dn",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .openEuler
        )
        XCTAssertEqual(openEuler.first?.choices.first?.replacement, "dnf")
        XCTAssertTrue(openEuler.first?.detail.contains("openEuler") == true)

        let unionTech = TerminalCommandCompletionEngine.suggestions(
            for: "ap",
            historyCommands: [],
            favoriteCommands: [],
            operatingSystem: .unionTechUOS
        )
        XCTAssertEqual(unionTech.first?.choices.first?.replacement, "apt")
        XCTAssertTrue(unionTech.first?.detail.contains("统信 UOS") == true)
    }

    func testLocalOperatingSystemOnlyShowsGenericFavorites() {
        let favorites = [
            TerminalFavoriteCommand(name: "Ubuntu only", command: "custom-ubuntu", operatingSystems: [.ubuntuDebian]),
            TerminalFavoriteCommand(name: "Everywhere", command: "custom-generic", operatingSystems: [.generic])
        ]
        let suggestions = TerminalCommandCompletionEngine.suggestions(
            for: "custom",
            favoriteCommands: favorites,
            operatingSystem: .generic
        )
        XCTAssertEqual(suggestions.first?.choices.map(\.replacement), ["custom-generic"])
    }

    func testPathChoicesRemainAfterCommandSources() {
        struct Provider: TerminalPathCompletionProviding {
            func candidates(for request: TerminalPathCompletionRequest) throws -> [TerminalPathCompletionCandidate] {
                [TerminalPathCompletionCandidate(name: "app", isDirectory: true)]
            }
        }
        let favorite = TerminalFavoriteCommand(name: "Open app", command: "cd /tmp/app", operatingSystems: [.generic])
        let suggestions = TerminalCommandCompletionEngine.suggestions(
            for: "cd /tmp/a",
            historyCommands: ["cd /tmp/archive"],
            favoriteCommands: [favorite],
            operatingSystem: .unknown,
            pathCompletionProvider: Provider()
        )
        let choices = suggestions.first?.choices ?? []
        XCTAssertTrue(choices.contains(where: { $0.kind == .favorite }))
        XCTAssertTrue(choices.contains(where: { $0.kind == .history }))
        XCTAssertTrue(choices.contains(where: { $0.kind == .path }))
    }

    func testCompletionPrioritizesFavoritesThenHistoryAndDeduplicates() throws {
        let favorites = [
            TerminalFavoriteCommand(name: "Deploy", command: "docker compose up", operatingSystems: [.generic]),
            TerminalFavoriteCommand(name: "Duplicate", command: "docker compose ps", operatingSystems: [.ubuntuDebian])
        ]
        let suggestions = TerminalCommandCompletionEngine.suggestions(
            for: "docker ",
            limit: 5,
            historyCommands: ["docker compose up", "docker compose logs"],
            favoriteCommands: favorites,
            operatingSystem: .unknown
        )

        XCTAssertEqual(suggestions.first?.choices.map(\.kind), [.favorite, .history])
        XCTAssertEqual(suggestions.first?.choices.map(\.replacement), ["docker compose up", "docker compose logs"])
        XCTAssertTrue(suggestions.first?.visibleText.contains("常用命令") == true)
        XCTAssertTrue(suggestions.first?.visibleText.contains("通用") == true)
    }

    func testTabAcceptsFavoriteWithoutExecuting() throws {
        let observer = TerminalCommandInputObserver()
        let favorite = TerminalFavoriteCommand(name: "Follow logs", command: "journalctl -f", operatingSystems: [.generic])

        let typed = observer.ingest(bytes: Array("journ".utf8), favoriteCommands: [favorite], operatingSystem: .unknown)
        XCTAssertEqual(typed.completionSuggestion?.selectedChoice.kind, .favorite)
        let accepted = observer.ingest(bytes: [9], favoriteCommands: [favorite], operatingSystem: .unknown)

        XCTAssertEqual(String(decoding: try XCTUnwrap(accepted.acceptedCompletionBytes), as: UTF8.self), "alctl -f")
        XCTAssertTrue(accepted.shouldConsumeInput)
        XCTAssertFalse(accepted.acceptedCompletionBytes?.contains(10) == true)
        XCTAssertEqual(accepted.currentLine, "journalctl -f")
    }

    func testTabAcceptsFavoriteAfterTrailingSpaceWithoutAddingAnotherSpace() throws {
        let observer = TerminalCommandInputObserver()
        let favorite = TerminalFavoriteCommand(name: "Compose up", command: "docker compose up", operatingSystems: [.generic])

        _ = observer.ingest(bytes: Array("docker ".utf8), favoriteCommands: [favorite])
        let accepted = observer.ingest(bytes: [9], favoriteCommands: [favorite])

        XCTAssertEqual(String(decoding: try XCTUnwrap(accepted.acceptedCompletionBytes), as: UTF8.self), "compose up")
        XCTAssertEqual(accepted.currentLine, "docker compose up")
    }

    func testRefreshingCompletionDropsDisabledFavoriteBeforeTabAcceptance() throws {
        let observer = TerminalCommandInputObserver()
        let favorite = TerminalFavoriteCommand(name: "Follow logs", command: "journalctl -f", operatingSystems: [.generic])

        _ = observer.ingest(bytes: Array("journ".utf8), favoriteCommands: [favorite], operatingSystem: .unknown)
        var disabled = favorite
        disabled.enabled = false

        let refreshed = observer.refreshCompletion(
            favoriteCommands: [disabled],
            operatingSystem: .unknown
        )
        XCTAssertNil(refreshed.completionSuggestion)

        let accepted = observer.ingest(
            bytes: [9],
            favoriteCommands: [disabled],
            operatingSystem: .unknown
        )
        XCTAssertNil(accepted.acceptedCompletionBytes)
    }

    func testCompletionDeduplicatesFavoriteAndBuiltInSubcommandByFullCommand() {
        let favorite = TerminalFavoriteCommand(name: "Git status", command: "git status", operatingSystems: [.generic])
        let suggestion = TerminalCommandCompletionEngine.suggestion(
            for: "git s",
            favoriteCommands: [favorite]
        )

        XCTAssertEqual(suggestion?.choices.map(\.deduplicationKey), ["git status", "git switch"])
        XCTAssertEqual(suggestion?.choices.filter { $0.deduplicationKey == "git status" }.count, 1)
        XCTAssertEqual(suggestion?.choices.first?.kind, .favorite)
    }

    func testHistoryPanelCanAddSelectedCommandToFavorites() {
        let controller = CommandHistoryViewController(timeZone: TimeZone(secondsFromGMT: 0)!)
        var added: String?
        controller.onAddToFavoriteCommand = { added = $0 }
        controller.loadView()
        controller.setEntries([TerminalCommandHistoryEntry(runtimeID: "term", command: "kubectl get pods", usedAt: Date(timeIntervalSince1970: 1))])
        controller.selectHistoryRowForTesting(0)
        controller.addSelectedCommandToFavoritesForTesting()
        XCTAssertEqual(added, "kubectl get pods")
        XCTAssertTrue(controller.visibleTextSnapshot.contains("添加到常用命令"))
    }

    func testFavoriteManagerReflectsStoreEntries() {
        let suiteName = "StacioFavoriteManager-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TerminalFavoriteCommandStore(defaults: defaults)
        _ = store.add(TerminalFavoriteCommand(name: "Status", command: "systemctl status", operatingSystems: [.centOSRHEL]))
        let controller = TerminalFavoriteCommandManagerViewController(store: store)
        controller.loadView()
        XCTAssertEqual(controller.numberOfRows(in: controller.tableView), 1)
        XCTAssertEqual(controller.tableView.tableColumns.count, 4)
        _ = store.add(TerminalFavoriteCommand(name: "Logs", command: "journalctl -f", operatingSystems: [.centOSRHEL]))
        XCTAssertEqual(controller.numberOfRows(in: controller.tableView), 2)
        controller.selectCommandRowForTesting(0)
        controller.toggleSelectedCommandForTesting()
        XCTAssertFalse(store.commands[0].enabled)
        controller.deleteSelectedCommandForTesting()
        XCTAssertEqual(store.commands.count, 1)
    }

    func testFavoriteEditorUsesCompactSheetAndShowsCompleteOperatingSystemCatalog() throws {
        let suiteName = "StacioFavoriteEditorLayout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = TerminalFavoriteCommandManagerViewController(
            store: TerminalFavoriteCommandStore(defaults: defaults)
        )
        let window = NSWindow(contentViewController: controller)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let add = try XCTUnwrap(
            findView("Stacio.FavoriteCommands.add", in: controller.view) as? NSButton
        )
        add.performClick(nil)
        let sheet = try XCTUnwrap(window.sheets.first)
        defer { window.endSheet(sheet) }
        let content = try XCTUnwrap(sheet.contentView)

        XCTAssertLessThanOrEqual(sheet.frame.width, 700)
        XCTAssertLessThanOrEqual(sheet.frame.height, 500)
        XCTAssertNotNil(findView("Stacio.FavoriteCommands.editor.name", in: content))
        XCTAssertNotNil(findView("Stacio.FavoriteCommands.editor.command", in: content))
        XCTAssertNotNil(findView("Stacio.FavoriteCommands.os.custom", in: content) as? NSTokenField)
        let osScroll = try XCTUnwrap(
            findView("Stacio.FavoriteCommands.os.scroll", in: content) as? NSScrollView
        )
        XCTAssertLessThanOrEqual(osScroll.frame.height, 130)
        let editableSystems = TerminalCommandOperatingSystem.allCases.filter { $0 != .unknown }
        for operatingSystem in editableSystems {
            XCTAssertNotNil(
                findView("Stacio.FavoriteCommands.os.\(operatingSystem.rawValue)", in: content),
                "Missing editor option for \(operatingSystem.displayName)"
            )
        }
    }

    func testFavoriteEditorSavesCustomOperatingSystemAndRemovesGenericScope() throws {
        let suiteName = "StacioFavoriteEditorCustomOS-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TerminalFavoriteCommandStore(defaults: defaults)
        let controller = TerminalFavoriteCommandManagerViewController(store: store)
        let window = NSWindow(contentViewController: controller)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let add = try XCTUnwrap(findView("Stacio.FavoriteCommands.add", in: controller.view) as? NSButton)
        add.performClick(nil)
        let sheet = try XCTUnwrap(window.sheets.first)
        let content = try XCTUnwrap(sheet.contentView)
        let name = try XCTUnwrap(findView("Stacio.FavoriteCommands.editor.name", in: content) as? NSTextField)
        let command = try XCTUnwrap(findView("Stacio.FavoriteCommands.editor.command", in: content) as? NSTextField)
        let custom = try XCTUnwrap(findView("Stacio.FavoriteCommands.os.custom", in: content) as? NSTokenField)
        let save = try XCTUnwrap(findView("Stacio.FavoriteCommands.save", in: content) as? NSButton)
        name.stringValue = "Neo service"
        command.stringValue = "neo-service status"
        custom.objectValue = ["Neo Linux", "银河实验系统"]
        save.performClick(nil)

        let saved = try XCTUnwrap(store.commands.first)
        XCTAssertEqual(saved.customOperatingSystems, ["Neo Linux", "银河实验系统"])
        XCTAssertTrue(saved.operatingSystems.isEmpty)
    }

    func testContextMenuOffersEnabledMatchingFavoritesWithoutExecution() {
        let favorite = TerminalFavoriteCommand(name: "List pods", command: "kubectl get pods", operatingSystems: [.generic])
        var inserted = ""
        let controller = TerminalContextMenuController(
            runtimeID: "terminal",
            paste: {},
            askAI: { _ in },
            favoriteCommands: { [favorite] },
            favoriteOperatingSystem: { .generic },
            insertFavoriteCommand: { inserted = $0 }
        )
        let menu = controller.makeMenu(selectedText: nil)
        let copy = try! XCTUnwrap(menu.items.first(where: { $0.title == L10n.Menu.copy }))
        XCTAssertFalse(copy.isEnabled)
        let explain = try! XCTUnwrap(menu.items.first(where: { $0.title == L10n.AI.explainSelection }))
        XCTAssertFalse(explain.isEnabled)
        let favorites = try! XCTUnwrap(menu.items.first(where: { $0.title == "常用命令" }))
        let item = try! XCTUnwrap(favorites.submenu?.items.first)
        XCTAssertTrue(NSApplication.shared.sendAction(item.action!, to: item.target, from: item))
        XCTAssertEqual(inserted, "kubectl get pods")
        XCTAssertFalse(inserted.hasSuffix("\n"))
    }

    func testContextMenuMatchesCustomOperatingSystemIdentity() throws {
        let favorite = TerminalFavoriteCommand(
            name: "Neo status",
            command: "neo-service status",
            operatingSystems: [],
            customOperatingSystems: ["Neo Linux"]
        )
        let controller = TerminalContextMenuController(
            runtimeID: "terminal",
            paste: {},
            askAI: { _ in },
            favoriteCommands: { [favorite] },
            favoriteOperatingSystem: { .unknown },
            favoriteOperatingSystemIdentity: { "Neo Linux Server 12" }
        )

        let menu = controller.makeMenu(selectedText: nil)
        let favorites = try XCTUnwrap(menu.items.first(where: { $0.title == "常用命令" }))
        XCTAssertEqual(favorites.submenu?.items.first?.title, "Neo status · neo-service status")
    }
}
