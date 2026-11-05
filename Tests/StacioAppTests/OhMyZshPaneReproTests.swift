import XCTest
import AppKit
@testable import StacioApp

/// 复现：选择 oh-my-zsh 后区域空白 + 无法切换其他选项。
@MainActor
final class OhMyZshPaneReproTests: XCTestCase {

    private func findSubview(_ view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let found = findSubview(subview, identifier: identifier) { return found }
        }
        return nil
    }

    func testOhMyZshPaneRendersAndAllowsSwitching() throws {
        let suiteName = "StacioSettingsRepro-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let controller = AppSettingsWindowController(settingsStore: store)
        controller.showWindow(nil)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)

        // 切到 oh-my-zsh
        let omzButton = try XCTUnwrap(
            findSubview(content, identifier: "Stacio.Settings.nav.ohMyZsh") as? NSButton
        )
        omzButton.performClick(nil)
        controller.window?.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // pane 不应空白：至少出现资源组标识
        XCTAssertNotNil(
            findSubview(content, identifier: "Stacio.Settings.group.ohMyZshResources"),
            "oh-my-zsh 区域不应空白"
        )
        let pluginsScrollView = try XCTUnwrap(
            findSubview(content, identifier: "Stacio.Settings.ohMyZshPlugins") as? NSScrollView
        )
        XCTAssertEqual(pluginsScrollView.frame.height, 220, accuracy: 1)
        XCTAssertEqual(pluginsScrollView.frame.width, 672, accuracy: 1)
        XCTAssertTrue(pluginsScrollView.hasVerticalScroller)
        let pluginsDocumentView = try XCTUnwrap(pluginsScrollView.documentView)
        XCTAssertEqual(
            pluginsDocumentView.frame.width,
            pluginsScrollView.contentView.bounds.width,
            accuracy: 1
        )

        // 还能切回 terminal
        let terminalButton = try XCTUnwrap(
            findSubview(content, identifier: "Stacio.Settings.nav.terminal") as? NSButton
        )
        terminalButton.performClick(nil)
        controller.window?.layoutIfNeeded()
        XCTAssertNotNil(findSubview(content, identifier: "Stacio.Settings.terminalTitle"), "切换回 terminal 应成功")
    }
}
