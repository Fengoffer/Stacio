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
        // Column 0: favorites (empty title), Column 1: time, Column 2: command
        XCTAssertEqual(controller.tableView.tableColumns.map(\.title), ["", "时间", "命令"])
        XCTAssertTrue(controller.tableView.viewText(atColumn: 1, row: 0).contains("2026-12-01"))
        XCTAssertTrue(controller.tableView.viewText(atColumn: 1, row: 0).contains("12:34:56"))
        XCTAssertEqual(controller.tableView.viewText(atColumn: 2, row: 0), "docker ps --format json")
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

    func testBatchSendPastesOneParsedCompoundCommandWithoutExecutingIt() {
        var pastedCommands: [String] = []
        let controller = CommandHistoryViewController()
        controller.onPasteCommand = { pastedCommands.append($0) }
        controller.loadView()
        controller.setEntries([
            historyEntry(id: "11111111-1111-1111-1111-111111111111", command: "pwd"),
            historyEntry(id: "22222222-2222-2222-2222-222222222222", command: "whoami"),
        ])

        controller.selectHistoryRowsForTesting(IndexSet([0, 1]))
        controller.pasteSelectedCommandForTesting()
        controller.sendSelectedCommandsForTesting()

        XCTAssertEqual(pastedCommands, ["pwd; whoami"])
    }

    func testBatchSendPreservesShellSyntaxWithoutExecutingIt() {
        var pastedCommands: [String] = []
        let controller = CommandHistoryViewController()
        controller.onPasteCommand = { pastedCommands.append($0) }
        controller.loadView()
        controller.setEntries([
            historyEntry(
                id: "11111111-1111-1111-1111-111111111111",
                command: "echo 'hello world'"
            ),
            historyEntry(
                id: "22222222-2222-2222-2222-222222222222",
                command: "printf \"%s\" done"
            ),
        ])

        controller.selectHistoryRowsForTesting(IndexSet([0, 1]))
        controller.sendSelectedCommandsForTesting()

        XCTAssertEqual(pastedCommands, ["echo 'hello world'; printf \"%s\" done"])
    }

    func testFilteringDoesNotRetargetSelectionToAnotherCommand() {
        var pastedCommands: [String] = []
        let controller = CommandHistoryViewController()
        controller.onPasteCommand = { pastedCommands.append($0) }
        controller.loadView()
        controller.setEntries([
            historyEntry(id: "11111111-1111-1111-1111-111111111111", command: "alpha"),
            historyEntry(id: "22222222-2222-2222-2222-222222222222", command: "beta"),
        ])
        controller.selectHistoryRowForTesting(1)

        controller.setSearchQueryForTesting("alpha")
        controller.pasteSelectedCommandForTesting()

        XCTAssertEqual(controller.commandsForTesting, ["alpha"])
        XCTAssertTrue(controller.tableView.selectedRowIndexes.isEmpty)
        XCTAssertTrue(pastedCommands.isEmpty)
    }

    func testUnfavoritingRefreshesDuplicateRowsAndRemovesFavoritesOnlyResults() {
        let suiteName = "StacioCommandHistoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandHistoryViewController(defaults: defaults)
        controller.loadView()
        controller.setEntries([
            historyEntry(id: "11111111-1111-1111-1111-111111111111", command: "git status"),
            historyEntry(id: "22222222-2222-2222-2222-222222222222", command: "git status"),
            historyEntry(id: "33333333-3333-3333-3333-333333333333", command: "pwd"),
        ])

        controller.toggleFavoriteForTesting(at: 0)
        controller.setFavoritesOnlyForTesting(true)
        XCTAssertEqual(controller.commandsForTesting, ["git status", "git status"])

        controller.toggleFavoriteForTesting(at: 0)

        XCTAssertTrue(controller.commandsForTesting.isEmpty)
        XCTAssertTrue(controller.statsTextForTesting.contains("★0"))
    }

    func testSearchHighlightUsesRangesFromOriginalUnicodeText() throws {
        let controller = CommandHistoryViewController()
        controller.loadView()
        controller.setEntries([
            historyEntry(id: "11111111-1111-1111-1111-111111111111", command: "İSTATUS"),
        ])

        controller.setSearchQueryForTesting("İ")

        let cell = try XCTUnwrap(
            controller.tableView.view(atColumn: 2, row: 0, makeIfNecessary: true) as? NSTableCellView
        )
        XCTAssertEqual(cell.textField?.attributedStringValue.string, "İSTATUS")
    }

    func testExportFailureIsReportedToTheUser() {
        struct ExportFailure: LocalizedError {
            var errorDescription: String? { "磁盘已满" }
        }
        let controller = CommandHistoryViewController(
            exportWriter: { _, _ in throw ExportFailure() }
        )
        var reportedMessages: [String] = []
        controller.onExportError = { reportedMessages.append($0) }
        controller.loadView()
        controller.setEntries([
            historyEntry(id: "11111111-1111-1111-1111-111111111111", command: "git status"),
        ])

        controller.exportHistoryForTesting(to: URL(fileURLWithPath: "/unwritable/history.txt"))

        XCTAssertEqual(reportedMessages, ["无法导出命令历史：磁盘已满"])
    }

    private func historyEntry(id: String, command: String) -> TerminalCommandHistoryEntry {
        TerminalCommandHistoryEntry(
            id: UUID(uuidString: id)!,
            runtimeID: "term_remote",
            command: command,
            usedAt: Date(timeIntervalSince1970: 100)
        )
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
