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
        let helpMenu = try XCTUnwrap(menu.item(withTitle: "帮助")?.submenu)

        let about = try XCTUnwrap(appMenu.item(withTitle: "关于 Stacio"))
        XCTAssertEqual(about.keyEquivalent, "")
        XCTAssertEqual(about.action, #selector(AppDelegate.showAboutPanel(_:)))

        let settings = try XCTUnwrap(appMenu.item(withTitle: "设置..."))
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.action, #selector(AppDelegate.showSettingsWindow(_:)))

        let newLocal = try XCTUnwrap(fileMenu.item(withTitle: "新建本地终端"))
        XCTAssertEqual(newLocal.keyEquivalent, "n")
        XCTAssertEqual(newLocal.action, #selector(AppDelegate.openLocalShellFromMenu(_:)))

        XCTAssertNil(fileMenu.item(withTitle: "快速连接"))

        let closeCurrent = try XCTUnwrap(fileMenu.item(withTitle: "关闭当前终端"))
        XCTAssertEqual(closeCurrent.keyEquivalent, "w")
        XCTAssertEqual(closeCurrent.action, #selector(AppDelegate.closeCurrentTerminalFromMenu(_:)))

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

        let split = try XCTUnwrap(terminalMenu.item(withTitle: "多执行分屏"))
        XCTAssertEqual(split.keyEquivalent, "d")
        XCTAssertEqual(split.action, #selector(AppDelegate.splitTerminalFromMenu(_:)))

        let dashboard = try XCTUnwrap(terminalMenu.item(withTitle: "显示/隐藏设备看板"))
        XCTAssertEqual(dashboard.keyEquivalent, "")
        XCTAssertEqual(dashboard.action, #selector(AppDelegate.toggleDeviceDashboardFromMenu(_:)))

        XCTAssertNil(helpMenu.item(withTitle: "Product Ops 设置"))
        XCTAssertNil(helpMenu.item(withTitle: "Product Ops 设置..."))

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
