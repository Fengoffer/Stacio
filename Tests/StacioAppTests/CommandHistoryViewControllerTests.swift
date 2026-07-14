import AppKit
import XCTest
@testable import StacioApp

@MainActor
final class CommandHistoryViewControllerTests: XCTestCase {
    func testHistoryTableShowsCommandAndConcreteTime() throws {
        let usedAt = Date(timeIntervalSince1970: 1_796_099_696)
        let controller = CommandHistoryViewController(timeZone: TimeZone(secondsFromGMT: 8 * 3_600)!)
        controller.loadView()

        controller.setEntries([
            TerminalCommandHistoryEntry(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                runtimeID: "term_remote",
                command: "docker ps --format json",
                usedAt: usedAt
            )
        ])

        XCTAssertEqual(controller.tableView.numberOfRows, 1)
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["时间", "命令"])
        XCTAssertTrue(controller.tableView.viewText(atColumn: 0, row: 0).contains("2026-12-01"))
        XCTAssertTrue(controller.tableView.viewText(atColumn: 0, row: 0).contains("12:34:56"))
        XCTAssertEqual(controller.tableView.viewText(atColumn: 1, row: 0), "docker ps --format json")
        XCTAssertFalse(controller.visibleTextSnapshot.contains("暂无历史命令"))
    }

    func testSelectedAndDoubleClickedHistoryCommandPasteIntoTerminal() throws {
        var pastedCommands: [String] = []
        let controller = CommandHistoryViewController()
        controller.onPasteCommand = { pastedCommands.append($0) }
        controller.loadView()
        controller.setEntries([
            TerminalCommandHistoryEntry(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                runtimeID: "term_remote",
                command: "tail -f /var/log/app.log",
                usedAt: Date(timeIntervalSince1970: 100)
            )
        ])

        controller.selectHistoryRowForTesting(0)
        controller.pasteSelectedCommandForTesting()
        controller.doubleClickSelectedCommandForTesting()

        XCTAssertEqual(pastedCommands, [
            "tail -f /var/log/app.log",
            "tail -f /var/log/app.log"
        ])
    }
}

private extension NSTableView {
    func viewText(atColumn column: Int, row: Int) -> String {
        guard let view = self.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView else {
            return ""
        }
        return view.textField?.stringValue ?? ""
    }
}
