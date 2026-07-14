import XCTest
@testable import StacioApp
import StacioCoreBindings

final class StacioCacheMaintenanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCacheMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    func testSummaryCountsRemoteEditAndStacioTemporaryCacheBytes() throws {
        let remoteCache = RemoteEditCache(
            rootDirectory: root.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        )
        let remoteItem = try remoteCache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 5),
            runtimeID: "runtime-a",
            sessionID: "session-a"
        )
        try Data(repeating: 0x61, count: 5).write(to: remoteItem.localURL)
        _ = try remoteCache.markDirty(itemID: remoteItem.id)

        let remoteFileCreateCache = root.appendingPathComponent("StacioRemoteFileCreate", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteFileCreateCache, withIntermediateDirectories: true)
        try Data(repeating: 0x62, count: 7)
            .write(to: remoteFileCreateCache.appendingPathComponent("draft.txt"))

        let maintenance = StacioCacheMaintenance(
            remoteEditCache: remoteCache,
            additionalCacheDirectories: [remoteFileCreateCache],
            fileManager: .default
        )

        let summary = try maintenance.cacheSummary()

        XCTAssertEqual(summary.totalBytes, 12)
        XCTAssertEqual(summary.dirtyRemoteEditItemCount, 1)
    }

    func testClearAllCachesRemovesOnlyConfiguredStacioCacheDirectories() throws {
        let remoteCache = RemoteEditCache(
            rootDirectory: root.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        )
        let remoteItem = try remoteCache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 11),
            runtimeID: "runtime-a",
            sessionID: "session-a"
        )
        try Data(repeating: 0x63, count: 11).write(to: remoteItem.localURL)

        let remoteFileCreateCache = root.appendingPathComponent("StacioRemoteFileCreate", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteFileCreateCache, withIntermediateDirectories: true)
        try Data(repeating: 0x64, count: 13)
            .write(to: remoteFileCreateCache.appendingPathComponent("draft.txt"))

        let nonCacheDirectory = root.appendingPathComponent("UserDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: nonCacheDirectory, withIntermediateDirectories: true)
        let nonCacheFile = nonCacheDirectory.appendingPathComponent("keep.txt")
        try Data(repeating: 0x65, count: 17).write(to: nonCacheFile)

        let maintenance = StacioCacheMaintenance(
            remoteEditCache: remoteCache,
            additionalCacheDirectories: [remoteFileCreateCache, nonCacheDirectory],
            fileManager: .default
        )

        let result = try maintenance.clearAllCaches()

        XCTAssertEqual(result.bytesCleared, 24)
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteItem.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: remoteFileCreateCache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonCacheFile.path))
        XCTAssertEqual(try maintenance.cacheSummary().totalBytes, 0)
    }

    func testClearAllCachesRejectsRemoteEditRootOutsideStacioOwnedCacheDirectory() throws {
        let nonCacheRoot = root
            .appendingPathComponent("UserDownloads", isDirectory: true)
            .appendingPathComponent("Remote Edit Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: nonCacheRoot, withIntermediateDirectories: true)
        let nonCacheFile = nonCacheRoot.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: nonCacheFile)
        let maintenance = StacioCacheMaintenance(
            remoteEditCache: RemoteEditCache(rootDirectory: nonCacheRoot),
            additionalCacheDirectories: [],
            fileManager: .default
        )

        XCTAssertThrowsError(try maintenance.clearAllCaches()) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .invalidCacheRoot)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: nonCacheFile.path))
    }
}
