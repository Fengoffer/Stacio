import XCTest
@testable import StacioApp

final class RemoteFileBackupNamingTests: XCTestCase {
    func testBackupFileNameAppendsTimestampBeforeBakWithoutSplittingExtension() {
        let timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 4,
            hour: 9,
            minute: 12
        ))!

        XCTAssertEqual(
            RemoteFileBackupNaming.backupFileName(originalFileName: "test", date: date, timeZone: timeZone),
            "test-202606040912.bak"
        )
        XCTAssertEqual(
            RemoteFileBackupNaming.backupFileName(originalFileName: "test.txt", date: date, timeZone: timeZone),
            "test.txt-202606040912.bak"
        )
    }

    func testRestoredFileNameRemovesOnlyTrailingTimestampBakSuffix() {
        XCTAssertEqual(
            RemoteFileBackupNaming.restoredFileName(fromBackupFileName: "test-202606040912.bak"),
            "test"
        )
        XCTAssertEqual(
            RemoteFileBackupNaming.restoredFileName(fromBackupFileName: "test.txt-202606040912.bak"),
            "test.txt"
        )
        XCTAssertNil(RemoteFileBackupNaming.restoredFileName(fromBackupFileName: "test.bak"))
        XCTAssertNil(RemoteFileBackupNaming.restoredFileName(fromBackupFileName: "test-202606040912.txt"))
    }
}
