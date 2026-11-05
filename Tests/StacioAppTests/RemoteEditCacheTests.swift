import XCTest
@testable import StacioApp
import StacioCoreBindings

final class RemoteEditCacheTests: XCTestCase {
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioRemoteEditCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let cacheRoot {
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        cacheRoot = nil
        try super.tearDownWithError()
    }

    func testCreateItemPreservesReadableRemoteFileName() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let selection = RemoteFileSelection(path: "/srv/app/config.prod.json", size: 42)

        let item = try cache.createItem(
            from: selection,
            runtimeID: "runtime-main",
            sessionID: "session-alpha",
            modifiedAt: Date(timeIntervalSince1970: 1_717_171_717)
        )

        XCTAssertEqual(item.remotePath, "/srv/app/config.prod.json")
        XCTAssertEqual(item.fileName, "config.prod.json")
        XCTAssertEqual(item.modifiedAt, Date(timeIntervalSince1970: 1_717_171_717))
        XCTAssertFalse(item.isDirty)
        XCTAssertEqual(item.localURL.lastPathComponent, "config.prod.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.localURL.path))
    }

    func testCreateItemSanitizesTraversalWithoutEscapingRoot() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let selection = RemoteFileSelection(path: "../../etc/ssh/../passwd", size: 8)

        let item = try cache.createItem(
            from: selection,
            runtimeID: "../runtime",
            sessionID: "session/../../escape"
        )

        XCTAssertEqual(item.fileName, "passwd")
        XCTAssertEqual(item.localURL.lastPathComponent, "passwd")
        XCTAssertTrue(item.localURL.path.hasPrefix(cacheRoot.path + "/"))
        XCTAssertFalse(item.localURL.path.contains(".."))
        XCTAssertFalse(item.localURL.deletingLastPathComponent().path.contains("/../"))
    }

    func testRuntimeAndSessionAreIsolated() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let selection = RemoteFileSelection(path: "/srv/app/config.json", size: 10)

        let first = try cache.createItem(from: selection, runtimeID: "runtime-a", sessionID: "session-1")
        let second = try cache.createItem(from: selection, runtimeID: "runtime-b", sessionID: "session-1")
        let third = try cache.createItem(from: selection, runtimeID: "runtime-a", sessionID: "session-2")

        XCTAssertNotEqual(first.localURL, second.localURL)
        XCTAssertNotEqual(first.localURL, third.localURL)
        XCTAssertTrue(first.localURL.path.contains("/runtime-a/"))
        XCTAssertTrue(second.localURL.path.contains("/runtime-b/"))
        XCTAssertTrue(third.localURL.path.contains("/session-2/"))
    }

    func testClearSessionRemovesOnlyMatchingSessionDirectoriesAndIndexes() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let targetRuntimeA = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/a.json", size: 10),
            runtimeID: "runtime-a",
            sessionID: "session-target"
        )
        let targetRuntimeB = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/b.json", size: 10),
            runtimeID: "runtime-b",
            sessionID: "session-target"
        )
        let otherSession = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/other.json", size: 10),
            runtimeID: "runtime-a",
            sessionID: "session-other"
        )
        try Data("target-a".utf8).write(to: targetRuntimeA.localURL)
        try Data("target-b".utf8).write(to: targetRuntimeB.localURL)
        try Data("other".utf8).write(to: otherSession.localURL)
        _ = try cache.markDirty(itemID: targetRuntimeB.id)

        try cache.clearSession(sessionID: "session-target")

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetRuntimeA.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetRuntimeB.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherSession.localURL.path))
        XCTAssertThrowsError(
            try cache.item(
                remotePath: targetRuntimeA.remotePath,
                runtimeID: targetRuntimeA.runtimeID,
                sessionID: targetRuntimeA.sessionID
            )
        )
        XCTAssertThrowsError(try cache.item(localURL: targetRuntimeB.localURL))
        XCTAssertEqual(
            try cache.item(
                remotePath: otherSession.remotePath,
                runtimeID: otherSession.runtimeID,
                sessionID: otherSession.sessionID
            ),
            otherSession
        )
        XCTAssertEqual(try cache.changedLocalCopies(runtimeID: "runtime-a", sessionID: "session-target"), [])

        let freshCache = RemoteEditCache(rootDirectory: cacheRoot)
        XCTAssertThrowsError(
            try freshCache.item(
                remotePath: targetRuntimeA.remotePath,
                runtimeID: targetRuntimeA.runtimeID,
                sessionID: targetRuntimeA.sessionID
            )
        )
        XCTAssertEqual(
            try freshCache.item(
                remotePath: otherSession.remotePath,
                runtimeID: otherSession.runtimeID,
                sessionID: otherSession.sessionID
            ),
            otherSession
        )
    }

    func testClearSessionUsesExactSessionIdentityForUnsafeSimilarIDs() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let unsafeSession = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/unsafe.json", size: 10),
            runtimeID: "runtime-a",
            sessionID: "session/alpha"
        )
        let literalSession = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/literal.json", size: 10),
            runtimeID: "runtime-a",
            sessionID: "session_alpha"
        )

        try cache.clearSession(sessionID: "session/alpha")

        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafeSession.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: literalSession.localURL.path))
        XCTAssertEqual(
            try cache.item(
                remotePath: literalSession.remotePath,
                runtimeID: literalSession.runtimeID,
                sessionID: literalSession.sessionID
            ),
            literalSession
        )
    }

    func testRemoveItemsForRuntimeDeletesOnlyThatRuntimeLocalCopies() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let target = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 10),
            runtimeID: "runtime-a",
            sessionID: "session-1"
        )
        let otherRuntime = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 10),
            runtimeID: "runtime-b",
            sessionID: "session-1"
        )
        let sameRuntimeOtherSession = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/other.json", size: 8),
            runtimeID: "runtime-a",
            sessionID: "session-2"
        )

        let removed = try cache.removeItems(runtimeID: "runtime-a")

        XCTAssertEqual(Set(removed.map(\.remotePath)), Set(["/srv/app/config.json", "/srv/app/other.json"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sameRuntimeOtherSession.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherRuntime.localURL.path))
        XCTAssertThrowsError(try cache.item(remotePath: target.remotePath, runtimeID: "runtime-a", sessionID: "session-1"))
        XCTAssertEqual(try cache.item(remotePath: otherRuntime.remotePath, runtimeID: "runtime-b", sessionID: "session-1"), otherRuntime)
    }

    func testFindItemByRemotePathRuntimeAndSession() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let selection = RemoteFileSelection(path: "/srv/app/config.json", size: 10)

        let item = try cache.createItem(from: selection, runtimeID: "runtime-a", sessionID: "session-1")

        XCTAssertEqual(
            try cache.item(remotePath: "/srv/app/config.json", runtimeID: "runtime-a", sessionID: "session-1"),
            item
        )
        XCTAssertThrowsError(
            try cache.item(remotePath: "/srv/app/config.json", runtimeID: "runtime-a", sessionID: "session-2")
        )
    }

    func testFindItemByLocalURLForOpenEditorTabs() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let selection = RemoteFileSelection(path: "/srv/app/config.json", size: 10)

        let item = try cache.createItem(from: selection, runtimeID: "runtime-a", sessionID: "session-1")

        XCTAssertEqual(try cache.item(localURL: item.localURL), item)
        XCTAssertThrowsError(
            try cache.item(localURL: cacheRoot.appendingPathComponent("missing.json"))
        )
    }

    func testMarkDirtyAndUploadJobSavesBackToOriginalRemotePath() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let selection = RemoteFileSelection(path: "/srv/app/config.json", size: 12)
        let item = try cache.createItem(from: selection, runtimeID: "runtime-a", sessionID: "session-1")

        let dirtyItem = try cache.markDirty(itemID: item.id)
        let job = try cache.makeUploadJob(for: dirtyItem)

        XCTAssertTrue(dirtyItem.isDirty)
        XCTAssertEqual(job.direction, .upload)
        XCTAssertEqual(job.sourcePath, dirtyItem.localURL.path)
        XCTAssertEqual(job.destinationPath, "/srv/app/config.json")
        XCTAssertEqual(job.bytesTotal, 0)
        XCTAssertTrue(job.id.hasPrefix("remote_edit_upload_"))
    }

    func testFreshMaintenanceInstanceCountsDirtyItemPersistedByDiscardedCacheInstance() throws {
        let productionRoot = cacheRoot.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        do {
            let cache = RemoteEditCache(rootDirectory: productionRoot)
            let item = try cache.createItem(
                from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
                runtimeID: "runtime-a",
                sessionID: "session-1",
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            try Data("local edits".utf8).write(to: item.localURL)
            _ = try cache.markDirty(itemID: item.id)
        }

        let freshCache = RemoteEditCache(rootDirectory: productionRoot)
        let maintenance = StacioCacheMaintenance(
            remoteEditCache: freshCache,
            additionalCacheDirectories: [],
            fileManager: .default
        )

        XCTAssertGreaterThan(try maintenance.cacheSummary().dirtyRemoteEditItemCount, 0)
        XCTAssertGreaterThan(freshCache.dirtyItemCount(), 0)
    }

    func testDownloadedCacheItemMarkedCleanRemainsCleanWhenScannedFromDisk() throws {
        let productionRoot = cacheRoot.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        let cache = RemoteEditCache(rootDirectory: productionRoot)
        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let downloadedAt = Date(timeIntervalSince1970: 1_800_000_600)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        try Data("downloaded".utf8).write(to: item.localURL)
        try FileManager.default.setAttributes([.modificationDate: downloadedAt], ofItemAtPath: item.localURL.path)

        let cleanItem = try cache.markClean(itemID: item.id)
        let freshMaintenance = StacioCacheMaintenance(
            remoteEditCache: RemoteEditCache(rootDirectory: productionRoot),
            additionalCacheDirectories: [],
            fileManager: .default
        )

        XCTAssertFalse(cleanItem.isDirty)
        XCTAssertEqual(try freshMaintenance.cacheSummary().dirtyRemoteEditItemCount, 0)
    }

    func testFreshCacheDetectsLocalContentModificationFromDiskWithoutMemoryIndex() throws {
        let productionRoot = cacheRoot.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        let cleanLocalModifiedAt = Date(timeIntervalSince1970: 1_800_000_600)
        do {
            let cache = RemoteEditCache(rootDirectory: productionRoot)
            let item = try cache.createItem(
                from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
                runtimeID: "runtime-a",
                sessionID: "session-1",
                modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            try Data("downloaded".utf8).write(to: item.localURL)
            try FileManager.default.setAttributes(
                [.modificationDate: cleanLocalModifiedAt],
                ofItemAtPath: item.localURL.path
            )
            _ = try cache.markClean(itemID: item.id)
        }

        let freshCache = RemoteEditCache(rootDirectory: productionRoot)
        let scannedItem = try freshCache.item(
            remotePath: "/srv/app/config.json",
            runtimeID: "runtime-a",
            sessionID: "session-1"
        )
        try Data("local edits".utf8).write(to: scannedItem.localURL)
        try FileManager.default.setAttributes(
            [.modificationDate: cleanLocalModifiedAt.addingTimeInterval(60)],
            ofItemAtPath: scannedItem.localURL.path
        )

        let rescannedCache = RemoteEditCache(rootDirectory: productionRoot)

        XCTAssertEqual(rescannedCache.dirtyItemCount(), 1)
        XCTAssertTrue(try rescannedCache.item(
            remotePath: "/srv/app/config.json",
            runtimeID: "runtime-a",
            sessionID: "session-1"
        ).isDirty)
    }

    func testFreshCacheSkipsCorruptMetadataAndKeepsValidItemsAvailable() throws {
        let productionRoot = cacheRoot.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        let validItem: RemoteEditCacheItem
        do {
            let cache = RemoteEditCache(rootDirectory: productionRoot)
            validItem = try cache.createItem(
                from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
                runtimeID: "runtime-a",
                sessionID: "session-1"
            )
        }
        let corruptDirectory = productionRoot.appendingPathComponent("aaa-corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        try Data("{not valid json".utf8).write(
            to: corruptDirectory.appendingPathComponent(".stacio-remote-edit-metadata.json")
        )

        let freshCache = RemoteEditCache(rootDirectory: productionRoot)

        XCTAssertEqual(freshCache.allItems(), [validItem])
        XCTAssertEqual(
            try freshCache.item(
                remotePath: validItem.remotePath,
                runtimeID: validItem.runtimeID,
                sessionID: validItem.sessionID
            ),
            validItem
        )
    }

    func testMarkCleanAfterSuccessfulUploadPersistsCleanStateToDisk() throws {
        let productionRoot = cacheRoot.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        let cache = RemoteEditCache(rootDirectory: productionRoot)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1"
        )
        try Data("local edits".utf8).write(to: item.localURL)
        let dirtyItem = try cache.markDirty(itemID: item.id)

        let cleanItem = try cache.markClean(itemID: dirtyItem.id)
        let freshCache = RemoteEditCache(rootDirectory: productionRoot)

        XCTAssertFalse(cleanItem.isDirty)
        XCTAssertEqual(freshCache.dirtyItemCount(), 0)
    }

    func testFailedUploadLeavesPersistedDirtyStateOnDisk() throws {
        let productionRoot = cacheRoot.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        let cache = RemoteEditCache(rootDirectory: productionRoot)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1"
        )
        try Data("local edits".utf8).write(to: item.localURL)

        _ = try cache.markDirty(itemID: item.id)
        let freshCache = RemoteEditCache(rootDirectory: productionRoot)

        XCTAssertEqual(freshCache.dirtyItemCount(), 1)
    }

    func testLocalCopyHasChangedReturnsTrueWhenLocalMtimeIsNewerThanRemoteModifiedAt() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )

        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(5)],
            ofItemAtPath: item.localURL.path
        )

        XCTAssertTrue(try cache.localCopyHasChanged(for: item))
        XCTAssertFalse(try cache.item(remotePath: item.remotePath, runtimeID: item.runtimeID, sessionID: item.sessionID).isDirty)
    }

    func testLocalCopyHasChangedReturnsFalseWhenLocalMtimeIsNotNewerThanRemoteModifiedAt() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )

        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(-5)],
            ofItemAtPath: item.localURL.path
        )
        XCTAssertFalse(try cache.localCopyHasChanged(for: item))

        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt],
            ofItemAtPath: item.localURL.path
        )
        XCTAssertFalse(try cache.localCopyHasChanged(for: item))
    }

    func testLocalCopyHasChangedReturnsFalseWhenRemoteModifiedAtIsUnknown() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: nil
        )

        try Data("local edits".utf8).write(to: item.localURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_010)],
            ofItemAtPath: item.localURL.path
        )

        XCTAssertFalse(try cache.localCopyHasChanged(for: item))
    }

    func testChangedLocalCopiesReturnsOnlyTrackedItemsWithNewerLocalMtimesInCreationOrder() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let firstChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/first.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let unchanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/unchanged.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let unknownRemoteModifiedAt = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/unknown.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: nil
        )
        let secondChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/second.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )

        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(5)],
            ofItemAtPath: firstChanged.localURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt],
            ofItemAtPath: unchanged.localURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(10)],
            ofItemAtPath: unknownRemoteModifiedAt.localURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(15)],
            ofItemAtPath: secondChanged.localURL.path
        )

        XCTAssertEqual(
            try cache.changedLocalCopies().map(\.remotePath),
            ["/srv/app/first.json", "/srv/app/second.json"]
        )
    }

    func testChangedLocalCopiesFiltersByRuntimeAndSessionInCreationOrder() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let otherRuntimeChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/other-runtime.json", size: 12),
            runtimeID: "runtime-b",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let firstTargetChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/first-target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let otherSessionChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/other-session.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-2",
            modifiedAt: remoteModifiedAt
        )
        let unchangedTarget = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/unchanged-target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let secondTargetChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/second-target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )

        for item in [otherRuntimeChanged, firstTargetChanged, otherSessionChanged, secondTargetChanged] {
            try FileManager.default.setAttributes(
                [.modificationDate: remoteModifiedAt.addingTimeInterval(5)],
                ofItemAtPath: item.localURL.path
            )
        }
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt],
            ofItemAtPath: unchangedTarget.localURL.path
        )

        XCTAssertEqual(
            try cache.changedLocalCopies(runtimeID: "runtime-a", sessionID: "session-1").map(\.remotePath),
            ["/srv/app/first-target.json", "/srv/app/second-target.json"]
        )
    }

    func testUploadJobsForChangedLocalCopiesBuildsJobsForRequestedRuntimeAndSession() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let otherRuntimeChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/other-runtime.json", size: 12),
            runtimeID: "runtime-b",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let firstTargetChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/first-target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let unchangedTarget = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/unchanged-target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let secondTargetChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/second-target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )

        try Data("first edit".utf8).write(to: firstTargetChanged.localURL)
        try Data("second edit".utf8).write(to: secondTargetChanged.localURL)
        for item in [otherRuntimeChanged, firstTargetChanged, secondTargetChanged] {
            try FileManager.default.setAttributes(
                [.modificationDate: remoteModifiedAt.addingTimeInterval(5)],
                ofItemAtPath: item.localURL.path
            )
        }
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt],
            ofItemAtPath: unchangedTarget.localURL.path
        )

        let jobs = try cache.makeUploadJobsForChangedLocalCopies(
            runtimeID: "runtime-a",
            sessionID: "session-1"
        )

        XCTAssertEqual(jobs.map(\.direction), [.upload, .upload])
        XCTAssertEqual(jobs.map(\.sourcePath), [
            firstTargetChanged.localURL.path,
            secondTargetChanged.localURL.path
        ])
        XCTAssertEqual(jobs.map(\.destinationPath), [
            "/srv/app/first-target.json",
            "/srv/app/second-target.json"
        ])
        XCTAssertEqual(jobs.map(\.bytesTotal), [10, 11])
        XCTAssertTrue(jobs.allSatisfy { $0.id.hasPrefix("remote_edit_upload_") })
        XCTAssertFalse(try cache.item(
            remotePath: firstTargetChanged.remotePath,
            runtimeID: firstTargetChanged.runtimeID,
            sessionID: firstTargetChanged.sessionID
        ).isDirty)
    }

    func testChangedLocalCopiesScopesMissingLocalCopyChecksToRequestedRuntimeAndSession() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let remoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let missingOtherRuntime = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/missing-other-runtime.json", size: 12),
            runtimeID: "runtime-b",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        let targetChanged = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        try FileManager.default.removeItem(at: missingOtherRuntime.localURL)
        try FileManager.default.setAttributes(
            [.modificationDate: remoteModifiedAt.addingTimeInterval(5)],
            ofItemAtPath: targetChanged.localURL.path
        )

        XCTAssertEqual(
            try cache.changedLocalCopies(runtimeID: "runtime-a", sessionID: "session-1").map(\.remotePath),
            ["/srv/app/target.json"]
        )

        let missingTarget = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/missing-target.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: remoteModifiedAt
        )
        try FileManager.default.removeItem(at: missingTarget.localURL)

        XCTAssertThrowsError(try cache.changedLocalCopies(runtimeID: "runtime-a", sessionID: "session-1")) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .localCopyMissing(missingTarget.localURL.path))
        }
    }

    func testChangedLocalCopiesThrowsWhenAnyTrackedLocalCopyIsMissing() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try FileManager.default.removeItem(at: item.localURL)

        XCTAssertThrowsError(try cache.changedLocalCopies()) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .localCopyMissing(item.localURL.path))
        }
    }

    func testChangedLocalCopiesIgnoresSupersededTrackedItemForSameRemotePath() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let olderRemoteModifiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let newerRemoteModifiedAt = olderRemoteModifiedAt.addingTimeInterval(60)
        let firstItem = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: olderRemoteModifiedAt
        )

        try FileManager.default.setAttributes(
            [.modificationDate: olderRemoteModifiedAt.addingTimeInterval(5)],
            ofItemAtPath: firstItem.localURL.path
        )
        let secondItem = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: newerRemoteModifiedAt
        )

        XCTAssertEqual(
            try cache.item(remotePath: "/srv/app/config.json", runtimeID: "runtime-a", sessionID: "session-1"),
            secondItem
        )
        XCTAssertEqual(try cache.changedLocalCopies(), [])
    }

    func testLocalCopyHasChangedRejectsMissingLocalCopy() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let item = try cache.createItem(
            from: RemoteFileSelection(path: "/srv/app/config.json", size: 12),
            runtimeID: "runtime-a",
            sessionID: "session-1",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try FileManager.default.removeItem(at: item.localURL)

        XCTAssertThrowsError(try cache.localCopyHasChanged(for: item)) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .localCopyMissing(item.localURL.path))
        }
    }

    func testLocalCopyHasChangedRejectsLocalPathOutsideCacheRoot() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let outsideURL = cacheRoot.deletingLastPathComponent().appendingPathComponent("outside-config.json")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data("outside".utf8).write(to: outsideURL)
        let item = RemoteEditCacheItem(
            id: "remote_edit_outside",
            runtimeID: "runtime-a",
            sessionID: "session-1",
            remotePath: "/srv/app/config.json",
            localURL: outsideURL,
            fileName: "config.json",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isDirty: false
        )

        XCTAssertThrowsError(try cache.localCopyHasChanged(for: item)) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .invalidLocalPath)
        }
    }

    func testUploadJobRejectsMissingLocalCopy() throws {
        let cache = RemoteEditCache(rootDirectory: cacheRoot)
        let selection = RemoteFileSelection(path: "/srv/app/config.json", size: 12)
        let item = try cache.createItem(from: selection, runtimeID: "runtime-a", sessionID: "session-1")

        try FileManager.default.removeItem(at: item.localURL)

        XCTAssertThrowsError(try cache.makeUploadJob(for: item)) { error in
            XCTAssertEqual(error as? RemoteEditCacheError, .localCopyMissing(item.localURL.path))
        }
    }
}
