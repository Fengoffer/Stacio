import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class StacioMenuBuilderTests: XCTestCase {
    func testMainMenuExposesChineseMacCommandsAndShortcuts() throws {
        let appDelegate = AppDelegate()
        let menu = StacioMenuBuilder(target: appDelegate).makeMainMenu()

        let appMenu = try XCTUnwrap(menu.item(withTitle: "Stacio")?.submenu)
        let fileMenu = try XCTUnwrap(menu.item(withTitle: "文件")?.submenu)
        let editMenu = try XCTUnwrap(menu.item(withTitle: "编辑")?.submenu)
        let terminalMenu = try XCTUnwrap(menu.item(withTitle: "终端")?.submenu)
        let viewMenu = try XCTUnwrap(menu.item(withTitle: "视图")?.submenu)
        let helpMenu = try XCTUnwrap(menu.item(withTitle: "帮助")?.submenu)

        let about = try XCTUnwrap(appMenu.item(withTitle: "关于 Stacio"))
        XCTAssertEqual(about.keyEquivalent, "")
        XCTAssertEqual(about.action, #selector(AppDelegate.showAboutPanel(_:)))

        let settings = try XCTUnwrap(appMenu.item(withTitle: "设置"))
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.action, #selector(AppDelegate.showSettingsWindow(_:)))

        let newSession = try XCTUnwrap(fileMenu.item(withTitle: "新建会话"))
        XCTAssertEqual(newSession.keyEquivalent, "n")
        XCTAssertEqual(newSession.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(newSession.action, #selector(AppDelegate.createSessionFromMenu(_:)))

        let newLocal = try XCTUnwrap(fileMenu.item(withTitle: "新建本地终端"))
        XCTAssertEqual(newLocal.keyEquivalent, "n")
        XCTAssertEqual(newLocal.action, #selector(AppDelegate.openLocalShellFromMenu(_:)))

        XCTAssertNil(fileMenu.item(withTitle: "快速连接"))

        let closeCurrent = try XCTUnwrap(fileMenu.item(withTitle: "关闭当前终端"))
        XCTAssertEqual(closeCurrent.keyEquivalent, "w")
        XCTAssertEqual(closeCurrent.action, #selector(AppDelegate.closeCurrentTerminalFromMenu(_:)))

        let importSessions = try XCTUnwrap(fileMenu.item(withTitle: "导入会话"))
        let importMenu = try XCTUnwrap(importSessions.submenu)
        XCTAssertEqual(importMenu.items.map(\.title), [
            "Stacio", "Xshell", "MobaXterm", "WindTerm", "SecureCRT",
            "FinalShell", "Termius", "Electerm", "JSON"
        ])
        XCTAssertTrue(importMenu.items.allSatisfy {
            $0.action == #selector(AppDelegate.importSessionsFromMenu(_:))
        })

        let cut = try XCTUnwrap(editMenu.item(withTitle: "剪切"))
        XCTAssertEqual(cut.keyEquivalent, "x")
        XCTAssertEqual(cut.action, #selector(NSText.cut(_:)))
        XCTAssertNil(cut.target)

        let copy = try XCTUnwrap(editMenu.item(withTitle: "复制"))
        XCTAssertEqual(copy.keyEquivalent, "c")
        XCTAssertEqual(copy.action, #selector(NSText.copy(_:)))
        XCTAssertNil(copy.target)

        let paste = try XCTUnwrap(editMenu.item(withTitle: "粘贴"))
        XCTAssertEqual(paste.keyEquivalent, "v")
        XCTAssertEqual(paste.action, #selector(NSText.paste(_:)))
        XCTAssertNil(paste.target)

        let selectAll = try XCTUnwrap(editMenu.item(withTitle: "全选"))
        XCTAssertEqual(selectAll.keyEquivalent, "a")
        XCTAssertEqual(selectAll.action, #selector(NSText.selectAll(_:)))
        XCTAssertNil(selectAll.target)

        let find = try XCTUnwrap(terminalMenu.item(withTitle: "查找"))
        XCTAssertEqual(find.keyEquivalent, "f")
        XCTAssertEqual(find.action, #selector(AppDelegate.findInTerminalMenu(_:)))

        let splitLayout = try XCTUnwrap(terminalMenu.item(withTitle: "分屏布局"))
        let splitLayoutMenu = try XCTUnwrap(splitLayout.submenu)
        XCTAssertEqual(splitLayoutMenu.items.map(\.title), ["单终端模式", "垂直分屏", "水平分屏", "网格分屏"])
        XCTAssertEqual(splitLayoutMenu.items.map(\.action), [
            #selector(AppDelegate.useSingleTerminalLayoutFromMenu(_:)),
            #selector(AppDelegate.splitTerminalVerticallyFromMenu(_:)),
            #selector(AppDelegate.splitTerminalHorizontallyFromMenu(_:)),
            #selector(AppDelegate.splitTerminalAsGridFromMenu(_:))
        ])

        let multiExec = try XCTUnwrap(terminalMenu.item(withTitle: "多执行"))
        XCTAssertEqual(multiExec.keyEquivalent, "d")
        XCTAssertEqual(multiExec.action, #selector(AppDelegate.performMultiExecFromMenu(_:)))

        XCTAssertNil(terminalMenu.item(withTitle: "显示/隐藏设备看板"))

        let visibleViewTitles = viewMenu.items
            .filter { $0.isSeparatorItem == false }
            .map(\.title)
        XCTAssertEqual(visibleViewTitles, [
            "显示/隐藏会话列表", "文件", "浏览器", "隧道", "显示/隐藏设备看板",
            "诊断", "宏", "历史命令", "AI 助手"
        ])
        XCTAssertEqual(
            viewMenu.item(withTitle: "显示/隐藏会话列表")?.action,
            #selector(AppDelegate.toggleSidebarFromMenu(_:))
        )
        XCTAssertEqual(viewMenu.item(withTitle: "文件")?.action, #selector(AppDelegate.showFilesFromMenu(_:)))
        XCTAssertEqual(viewMenu.item(withTitle: "浏览器")?.action, #selector(AppDelegate.showBrowserFromMenu(_:)))
        XCTAssertEqual(viewMenu.item(withTitle: "隧道")?.action, #selector(AppDelegate.showTunnelsFromMenu(_:)))
        XCTAssertEqual(
            viewMenu.item(withTitle: "显示/隐藏设备看板")?.action,
            #selector(AppDelegate.toggleDeviceDashboardFromMenu(_:))
        )
        XCTAssertEqual(viewMenu.item(withTitle: "诊断")?.action, #selector(AppDelegate.showDiagnosticsFromMenu(_:)))
        XCTAssertEqual(viewMenu.item(withTitle: "宏")?.action, #selector(AppDelegate.showTerminalMacrosFromMenu(_:)))
        XCTAssertEqual(
            viewMenu.item(withTitle: "历史命令")?.action,
            #selector(AppDelegate.showCommandHistoryFromMenu(_:))
        )
        XCTAssertEqual(viewMenu.item(withTitle: "AI 助手")?.action, #selector(AppDelegate.showAIAssistantFromMenu(_:)))

        XCTAssertNil(helpMenu.item(withTitle: "Product Ops 设置"))
        XCTAssertNil(helpMenu.item(withTitle: "Product Ops 设置..."))
        XCTAssertEqual(helpMenu.minimumWidth, 240)

        let feedback = try XCTUnwrap(helpMenu.item(withTitle: "反馈"))
        XCTAssertEqual(feedback.keyEquivalent, "")
        XCTAssertEqual(feedback.action, #selector(AppDelegate.showFeedbackWindow(_:)))

        let update = try XCTUnwrap(helpMenu.item(withTitle: "检查更新"))
        XCTAssertEqual(update.keyEquivalent, "")
        XCTAssertEqual(update.action, #selector(AppDelegate.showUpdateCheckWindow(_:)))

        let license = try XCTUnwrap(helpMenu.item(withTitle: "License"))
        XCTAssertEqual(license.keyEquivalent, "")
        XCTAssertEqual(license.action, #selector(AppDelegate.showLicenseWindow(_:)))
    }
}
