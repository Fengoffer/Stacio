import AppKit
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class TerminalMouseBehaviorTests: XCTestCase {
    func testRightMouseActionUsesOptionAsPasteModeMenuFallback() {
        XCTAssertEqual(
            StacioTerminalMouseBehavior.rightMouseDownAction(
                behavior: .paste,
                modifierFlags: []
            ),
            .paste
        )
        XCTAssertEqual(
            StacioTerminalMouseBehavior.rightMouseDownAction(
                behavior: .paste,
                modifierFlags: .option
            ),
            .contextMenu
        )
        XCTAssertEqual(
            StacioTerminalMouseBehavior.rightMouseDownAction(
                behavior: .contextMenu,
                modifierFlags: .option
            ),
            .contextMenu
        )
        XCTAssertEqual(
            StacioTerminalMouseBehavior.rightMouseDownAction(
                behavior: .none,
                modifierFlags: .option
            ),
            .none
        )
    }

    func testPasteModePastesOnOrdinaryRightClickForLocalAndRemoteTerminals() {
        for terminalView in makeTerminalViews() {
            let store = makeSettingsStore(behavior: .paste)
            var pasteCount = 0
            var menuPresentationCount = 0

            StacioTerminalMouseBehavior.handleRightMouseDown(
                in: terminalView,
                event: rightMouseEvent(modifierFlags: []),
                settingsStore: store,
                contextMenuProvider: { _ in NSMenu(title: "Terminal") },
                pasteAction: { pasteCount += 1 },
                contextMenuAction: { _ in menuPresentationCount += 1 }
            )

            XCTAssertEqual(pasteCount, 1)
            XCTAssertEqual(menuPresentationCount, 0)
        }
    }

    func testOptionRightClickInPasteModePresentsMenuWithoutPastingForLocalAndRemoteTerminals() {
        for terminalView in makeTerminalViews() {
            let store = makeSettingsStore(behavior: .paste)
            let menu = NSMenu(title: "Terminal")
            var pasteCount = 0
            var presentedMenus: [NSMenu] = []

            StacioTerminalMouseBehavior.handleRightMouseDown(
                in: terminalView,
                event: rightMouseEvent(modifierFlags: .option),
                settingsStore: store,
                contextMenuProvider: { _ in menu },
                pasteAction: { pasteCount += 1 },
                contextMenuAction: { presentedMenus.append($0) }
            )

            XCTAssertEqual(pasteCount, 0)
            XCTAssertEqual(presentedMenus.count, 1)
            XCTAssertTrue(presentedMenus.first === menu)
        }
    }

    func testContextMenuAndNoneModesRemainUnchangedWithOptionRightClick() {
        for behavior in [TerminalRightClickBehaviorPreference.contextMenu, .none] {
            for terminalView in makeTerminalViews() {
                let store = makeSettingsStore(behavior: behavior)
                var pasteCount = 0
                var menuPresentationCount = 0

                StacioTerminalMouseBehavior.handleRightMouseDown(
                    in: terminalView,
                    event: rightMouseEvent(modifierFlags: .option),
                    settingsStore: store,
                    contextMenuProvider: { _ in NSMenu(title: "Terminal") },
                    pasteAction: { pasteCount += 1 },
                    contextMenuAction: { _ in menuPresentationCount += 1 }
                )

                if behavior == .contextMenu {
                    XCTAssertEqual(pasteCount, 0)
                    XCTAssertEqual(menuPresentationCount, 1)
                } else {
                    XCTAssertEqual(pasteCount, 0)
                    XCTAssertEqual(menuPresentationCount, 0)
                }
            }
        }
    }

    private func makeTerminalViews() -> [TerminalView] {
        [
            StacioLocalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400)),
            StacioRemoteTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        ]
    }

    private func makeSettingsStore(behavior: TerminalRightClickBehaviorPreference) -> AppSettingsStore {
        let suiteName = "StacioAppTests.TerminalMouseBehaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.terminalRightClickBehavior = behavior
        }
        return store
    }

    private func rightMouseEvent(modifierFlags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }
}
