import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class StacioShortcutStoreTests: XCTestCase {
    func testDefaultsExposeMenuBindings() {
        let store = StacioShortcutStore(defaults: UserDefaults())
        XCTAssertEqual(store.binding(for: .newSession), StacioShortcutBinding(key: "n", modifiers: [.command, .shift]))
        XCTAssertEqual(store.binding(for: .closeTerminal).displayString, "⌘W")
        XCTAssertEqual(store.binding(for: .showAIAssistant), StacioShortcutBinding(key: "a", modifiers: [.command, .shift]))
    }

    func testSpecialKeysMapToNativeMenuEquivalents() {
        XCTAssertEqual(StacioShortcutBinding(key: "return").menuKeyEquivalent, "\r")
        XCTAssertEqual(StacioShortcutBinding(key: "delete").menuKeyEquivalent, "\u{8}")
        XCTAssertEqual(StacioShortcutBinding(key: "tab").displayString, "⌘⇥")
        XCTAssertEqual(StacioShortcutBinding(key: "left").displayString, "⌘←")
        XCTAssertEqual(
            StacioShortcutBinding(key: "left").menuKeyEquivalent,
            String(UnicodeScalar(0xF702)!)
        )
    }

    func testDuplicateAndSystemConflictsAreReportedWithoutMutation() {
        let defaults = UserDefaults()
        let store = StacioShortcutStore(defaults: defaults)
        let original = store.binding(for: .find)
        XCTAssertEqual(
            store.conflict(for: store.binding(for: .newLocalTerminal), excluding: .find),
            .duplicate(StacioShortcutAction.newLocalTerminal.title)
        )
        XCTAssertEqual(
            store.set(.init(key: " ", modifiers: [.command]), for: .find),
            .systemReserved("聚焦 Spotlight")
        )
        XCTAssertEqual(store.binding(for: .find), original)
    }

    func testValidChangePersistsAndNotifies() {
        let defaults = UserDefaults()
        let store = StacioShortcutStore(defaults: defaults)
        let expectation = expectation(description: "shortcut changed")
        let token = NotificationCenter.default.addObserver(
            forName: StacioShortcutStore.didChangeNotification,
            object: store,
            queue: .main
        ) { _ in expectation.fulfill() }
        XCTAssertEqual(store.set(.init(key: "k", modifiers: [.command, .option]), for: .find), .none)
        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(token)
        let restored = StacioShortcutStore(defaults: defaults)
        XCTAssertEqual(restored.binding(for: .find), .init(key: "k", modifiers: [.command, .option]))
    }
}
