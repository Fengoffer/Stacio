import XCTest
@testable import StacioApp

final class StacioPathsTests: XCTestCase {
    func testBuildsApplicationSupportDatabasePathAndCreatesDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = try StacioPaths(
            applicationSupportDirectory: root,
            fileManager: .default
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(paths.databaseURL.lastPathComponent, "Stacio.sqlite")
        XCTAssertEqual(paths.databaseURL.deletingLastPathComponent().path, root.path)
    }

    func testMigratesLegacyApplicationSupportByCopyingAndLeavingMarker() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let legacy = tempRoot.appendingPathComponent("Stacio", isDirectory: true)
        let stacio = tempRoot.appendingPathComponent("Stacio", isDirectory: true)
        let nested = legacy.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("saved-session".utf8).write(to: nested.appendingPathComponent("session.json"))

        try StacioPaths.migrateLegacyApplicationSupportIfNeeded(
            legacyDirectory: legacy,
            stacioDirectory: stacio,
            fileManager: .default
        )
        try StacioPaths.migrateLegacyApplicationSupportIfNeeded(
            legacyDirectory: legacy,
            stacioDirectory: stacio,
            fileManager: .default
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stacio.appendingPathComponent("Sessions/session.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacy.appendingPathComponent(StacioPaths.migrationMarkerFileName).path
            )
        )
    }

    func testMigrationPreservesExistingStacioFiles() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let legacy = tempRoot.appendingPathComponent("Stacio", isDirectory: true)
        let stacio = tempRoot.appendingPathComponent("Stacio", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stacio, withIntermediateDirectories: true)
        let fileName = "Stacio.sqlite"
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent(fileName))
        try Data("current".utf8).write(to: stacio.appendingPathComponent(fileName))

        try StacioPaths.migrateLegacyApplicationSupportIfNeeded(
            legacyDirectory: legacy,
            stacioDirectory: stacio,
            fileManager: .default
        )

        let migratedData = try Data(contentsOf: stacio.appendingPathComponent(fileName))
        XCTAssertEqual(String(data: migratedData, encoding: .utf8), "current")
    }

    func testMigrationCopiesLegacyDatabaseToStacioDatabaseName() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let legacy = tempRoot.appendingPathComponent("Stacio", isDirectory: true)
        let stacio = tempRoot.appendingPathComponent("Stacio", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("legacy-db".utf8).write(to: legacy.appendingPathComponent("Stacio.sqlite"))

        try StacioPaths.migrateLegacyApplicationSupportIfNeeded(
            legacyDirectory: legacy,
            stacioDirectory: stacio,
            fileManager: .default
        )

        XCTAssertEqual(
            try String(contentsOf: stacio.appendingPathComponent("Stacio.sqlite"), encoding: .utf8),
            "legacy-db"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stacio.appendingPathComponent("Stacio.sqlite").path))
    }
}
