import XCTest
@testable import StacioApp

@MainActor
final class TerminalCommandHistoryStoreTests: XCTestCase {
    func testRecordTrimsSubmittedCommandsAndListsNewestFirstPerRuntime() throws {
        var dates = [
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 20),
            Date(timeIntervalSince1970: 30)
        ]
        let store = TerminalCommandHistoryStore(dateProvider: { dates.removeFirst() })

        XCTAssertNil(store.record(runtimeID: "term_a", command: "   \n"))
        _ = store.record(runtimeID: "term_a", command: "  pwd  \n")
        _ = store.record(runtimeID: "term_b", command: "whoami")
        _ = store.record(runtimeID: "term_a", command: "ls -la")

        XCTAssertEqual(store.entries(for: "term_a").map(\.command), ["ls -la", "pwd"])
        XCTAssertEqual(store.entries(for: "term_a").map(\.usedAt), [
            Date(timeIntervalSince1970: 30),
            Date(timeIntervalSince1970: 10)
        ])
        XCTAssertEqual(store.entries(for: "term_b").map(\.command), ["whoami"])
    }

    func testStoreCapsHistoryPerRuntime() throws {
        var nextTime: TimeInterval = 0
        let store = TerminalCommandHistoryStore(maxEntriesPerRuntime: 2) {
            nextTime += 1
            return Date(timeIntervalSince1970: nextTime)
        }

        _ = store.record(runtimeID: "term_a", command: "first")
        _ = store.record(runtimeID: "term_a", command: "second")
        _ = store.record(runtimeID: "term_a", command: "third")

        XCTAssertEqual(store.entries(for: "term_a").map(\.command), ["third", "second"])
    }
}
