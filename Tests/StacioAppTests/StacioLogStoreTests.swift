import XCTest
@testable import StacioApp

final class StacioLogStoreTests: XCTestCase {
    func testSharedLogStoreDoesNotWriteDefaultUserLogDuringSwiftTests() throws {
        let logURL = try StacioPaths()
            .applicationSupportDirectory
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("stacio.log")
        let marker = "unit-test-shared-log-\(UUID().uuidString)"
        let before = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""

        StacioLogStore.shared.append(
            level: .info,
            category: "Test",
            message: marker
        )

        let after = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(after, before)
        XCTAssertFalse(after.contains(marker))
        XCTAssertNotEqual(StacioLogStore.shared.logFileURL.standardizedFileURL.path, logURL.standardizedFileURL.path)
    }

    func testLogStoreWritesRecentRedactedLinesToDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLogStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("stacio.log")
        let store = StacioLogStore(logFileURL: logURL)

        store.append(
            level: .info,
            category: "Files",
            message: "open /srv/app/config.json with password hunter2",
            sensitiveValues: ["hunter2"]
        )
        store.append(level: .error, category: "VNC", message: "viewer failed")

        let lines = try store.recentLines(limit: 10)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[INFO]"))
        XCTAssertTrue(lines[0].contains("[Files]"))
        XCTAssertTrue(lines[0].contains("/srv/app/config.json"))
        XCTAssertTrue(lines[0].contains("[已隐藏凭据]"))
        XCTAssertFalse(lines.joined(separator: "\n").contains("hunter2"))
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("viewer failed"))
    }

    func testLogStoreReturnsOnlyRequestedRecentLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLogStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StacioLogStore(logFileURL: root.appendingPathComponent("stacio.log"))

        store.append(level: .info, category: "Test", message: "line 1")
        store.append(level: .info, category: "Test", message: "line 2")
        store.append(level: .info, category: "Test", message: "line 3")

        let lines = try store.recentLines(limit: 2)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("line 2"))
        XCTAssertTrue(lines[1].contains("line 3"))
    }
}
