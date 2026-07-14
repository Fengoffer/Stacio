import Foundation
import StacioCoreBindings

public enum RemoteEditCacheError: Error, Equatable {
    case invalidCacheRoot
    case invalidLocalPath
    case itemNotFound(String)
    case localCopyMissing(String)
    case remoteChanged(String)
    case remoteWriteVerificationFailed(String)
}

public struct RemoteEditCacheItem: Equatable, Sendable {
    public let id: String
    public let runtimeID: String
    public let sessionID: String
    public let remotePath: String
    public let localURL: URL
    public let fileName: String
    public let modifiedAt: Date?
    public let isDirty: Bool
}

public protocol RemoteEditSessionCacheClearing: AnyObject {
    func clearSession(sessionID: String) throws
}

public final class RemoteEditCache {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let sessionIdentityFileName = ".stacio-session-id"
    private let itemMetadataFileName = ".stacio-remote-edit-metadata.json"
    private var itemsByID: [String: RemoteEditCacheItem] = [:]
    private var itemIDsInCreationOrder: [String] = []
    private var itemIDsByKey: [String: String] = [:]
    private var cleanLocalModifiedAtByItemID: [String: Date] = [:]

    private struct RemoteEditCacheItemMetadata: Codable {
        let schemaVersion: Int
        let id: String
        let runtimeID: String
        let sessionID: String
        let remotePath: String
        let fileName: String
        let localPath: String?
        let modifiedAt: Date?
        let cleanLocalModifiedAt: Date?
        let isDirty: Bool
    }

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    public var cacheRootURL: URL {
        rootDirectory
    }

    public static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        (
            try? StacioPaths(fileManager: fileManager)
        )?.applicationSupportDirectory
            .appendingPathComponent("Remote Edit Cache", isDirectory: true)
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
    }

    public static func defaultCache(fileManager: FileManager = .default) -> RemoteEditCache {
        RemoteEditCache(rootDirectory: defaultRootDirectory(fileManager: fileManager), fileManager: fileManager)
    }

    public func createItem(
        from selection: RemoteFileSelection,
        runtimeID: String,
        sessionID: String,
        modifiedAt: Date? = nil,
        existingLocalFileURL: URL? = nil
    ) throws -> RemoteEditCacheItem {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let fileName = readableFileName(from: selection.path)
        let sessionDirectory = rootDirectory
            .appendingPathComponent(safeIdentitySegment(runtimeID), isDirectory: true)
            .appendingPathComponent(safeIdentitySegment(sessionID), isDirectory: true)
        let localDirectory = sessionDirectory
            .appendingPathComponent(remotePathFingerprint(selection.path), isDirectory: true)
        try fileManager.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        try writeSessionIdentityMarker(sessionID, in: sessionDirectory)

        let localURL = localDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard isInsideCache(localURL) else {
            throw RemoteEditCacheError.invalidLocalPath
        }

        if let existingLocalFileURL {
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.copyItem(at: existingLocalFileURL, to: localURL)
        } else if !fileManager.fileExists(atPath: localURL.path) {
            fileManager.createFile(atPath: localURL.path, contents: Data())
        }

        let item = RemoteEditCacheItem(
            id: "remote_edit_\(UUID().uuidString)",
            runtimeID: runtimeID,
            sessionID: sessionID,
            remotePath: selection.path,
            localURL: localURL,
            fileName: fileName,
            modifiedAt: modifiedAt,
            isDirty: false
        )
        storeTrackedItem(item)
        try writeMetadata(for: item, cleanLocalModifiedAt: nil)
        return item
    }

    public func item(remotePath: String, runtimeID: String, sessionID: String) throws -> RemoteEditCacheItem {
        try refreshItemsFromDisk()
        let key = itemKey(remotePath: remotePath, runtimeID: runtimeID, sessionID: sessionID)
        guard let itemID = itemIDsByKey[key],
              let item = itemsByID[itemID]
        else {
            throw RemoteEditCacheError.itemNotFound(remotePath)
        }
        return item
    }

    public func item(localURL: URL) throws -> RemoteEditCacheItem {
        try refreshItemsFromDisk()
        let normalizedPath = localURL.standardizedFileURL.path
        for itemID in itemIDsInCreationOrder {
            guard let item = itemsByID[itemID] else {
                continue
            }
            if item.localURL.standardizedFileURL.path == normalizedPath {
                return item
            }
        }
        throw RemoteEditCacheError.itemNotFound(localURL.path)
    }

    public func registerItem(
        remotePath: String,
        localURL: URL,
        runtimeID: String,
        sessionID: String,
        modifiedAt: Date? = nil,
        isDirty: Bool = false
    ) throws -> RemoteEditCacheItem {
        guard isInsideCache(localURL) else {
            throw RemoteEditCacheError.invalidLocalPath
        }
        guard fileManager.fileExists(atPath: localURL.path) else {
            throw RemoteEditCacheError.localCopyMissing(localURL.path)
        }
        let item = RemoteEditCacheItem(
            id: "remote_edit_\(UUID().uuidString)",
            runtimeID: runtimeID,
            sessionID: sessionID,
            remotePath: remotePath,
            localURL: localURL,
            fileName: localURL.lastPathComponent,
            modifiedAt: modifiedAt,
            isDirty: isDirty
        )
        storeTrackedItem(item)
        try writeMetadata(
            for: item,
            cleanLocalModifiedAt: isDirty ? nil : localFileModificationDate(at: localURL)
        )
        return item
    }

    func registerItemForTesting(
        remotePath: String,
        localURL: URL,
        runtimeID: String,
        sessionID: String,
        modifiedAt: Date? = nil,
        isDirty: Bool = false
    ) throws -> RemoteEditCacheItem {
        guard fileManager.fileExists(atPath: localURL.path) else {
            throw RemoteEditCacheError.localCopyMissing(localURL.path)
        }
        let item = RemoteEditCacheItem(
            id: "remote_edit_test_\(UUID().uuidString)",
            runtimeID: runtimeID,
            sessionID: sessionID,
            remotePath: remotePath,
            localURL: localURL,
            fileName: localURL.lastPathComponent,
            modifiedAt: modifiedAt,
            isDirty: isDirty
        )
        storeTrackedItem(item)
        let cleanLocalModifiedAt = isDirty ? nil : localFileModificationDate(at: localURL)
        cleanLocalModifiedAtByItemID[item.id] = cleanLocalModifiedAt
        if isInsideCache(localURL) {
            try writeMetadata(for: item, cleanLocalModifiedAt: cleanLocalModifiedAt)
        }
        return item
    }

    @discardableResult
    public func removeItems(runtimeID: String) throws -> [RemoteEditCacheItem] {
        try refreshItemsFromDisk()
        let removed = itemIDsInCreationOrder.compactMap { itemsByID[$0] }.filter { $0.runtimeID == runtimeID }
        guard removed.isEmpty == false else {
            return []
        }

        for item in removed {
            let key = itemKey(remotePath: item.remotePath, runtimeID: item.runtimeID, sessionID: item.sessionID)
            itemIDsByKey[key] = nil
            itemsByID[item.id] = nil
            cleanLocalModifiedAtByItemID[item.id] = nil
            try? removeCachedItemDirectory(for: item)
        }
        itemIDsInCreationOrder.removeAll { itemID in
            removed.contains { $0.id == itemID }
        }
        removeEmptyRuntimeDirectory(runtimeID: runtimeID)
        return removed
    }

    public func allItems() -> [RemoteEditCacheItem] {
        try? refreshItemsFromDisk()
        return itemIDsInCreationOrder.compactMap { itemsByID[$0] }
    }

    public func clearSession(sessionID: String) throws {
        try refreshItemsFromDisk()
        let removed = trackedItems { $0.sessionID == sessionID }
        let directories = try sessionDirectories(for: sessionID)
        for directory in directories {
            guard isInsideCache(directory) else {
                throw RemoteEditCacheError.invalidLocalPath
            }
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        for item in removed where fileManager.fileExists(atPath: item.localURL.path) {
            guard isInsideCache(item.localURL) else {
                throw RemoteEditCacheError.invalidLocalPath
            }
            try fileManager.removeItem(at: item.localURL)
        }
        removeTrackedItems { $0.sessionID == sessionID }
    }

    public func clearAll() throws {
        if fileManager.fileExists(atPath: rootDirectory.path) {
            guard isInsideCache(rootDirectory) else {
                throw RemoteEditCacheError.invalidCacheRoot
            }
            try fileManager.removeItem(at: rootDirectory)
        }
        itemsByID.removeAll()
        itemIDsInCreationOrder.removeAll()
        itemIDsByKey.removeAll()
        cleanLocalModifiedAtByItemID.removeAll()
    }

    public func cacheSizeBytes() throws -> UInt64 {
        try directorySize(at: rootDirectory)
    }

    public func dirtyItemCount() -> Int {
        try? refreshItemsFromDisk()
        return itemIDsInCreationOrder.reduce(into: 0) { count, itemID in
            guard let item = itemsByID[itemID] else {
                return
            }
            if item.isDirty || ((try? localCopyHasChanged(for: item)) ?? false) {
                count += 1
            }
        }
    }

    public func markDirty(itemID: String) throws -> RemoteEditCacheItem {
        guard let item = itemsByID[itemID] else {
            throw RemoteEditCacheError.itemNotFound(itemID)
        }
        let dirtyItem = RemoteEditCacheItem(
            id: item.id,
            runtimeID: item.runtimeID,
            sessionID: item.sessionID,
            remotePath: item.remotePath,
            localURL: item.localURL,
            fileName: item.fileName,
            modifiedAt: item.modifiedAt,
            isDirty: true
        )
        itemsByID[itemID] = dirtyItem
        try writeMetadata(for: dirtyItem, cleanLocalModifiedAt: cleanLocalModifiedAtByItemID[itemID])
        return dirtyItem
    }

    public func markClean(itemID: String) throws -> RemoteEditCacheItem {
        guard let item = itemsByID[itemID] else {
            throw RemoteEditCacheError.itemNotFound(itemID)
        }
        let cleanItem = RemoteEditCacheItem(
            id: item.id,
            runtimeID: item.runtimeID,
            sessionID: item.sessionID,
            remotePath: item.remotePath,
            localURL: item.localURL,
            fileName: item.fileName,
            modifiedAt: item.modifiedAt,
            isDirty: false
        )
        let cleanLocalModifiedAt = localFileModificationDate(at: item.localURL)
        itemsByID[itemID] = cleanItem
        try writeMetadata(for: cleanItem, cleanLocalModifiedAt: cleanLocalModifiedAt)
        return cleanItem
    }

    public func makeUploadJob(for item: RemoteEditCacheItem) throws -> ScpTransferJob {
        guard isInsideCache(item.localURL) else {
            throw RemoteEditCacheError.invalidLocalPath
        }
        guard fileManager.fileExists(atPath: item.localURL.path) else {
            throw RemoteEditCacheError.localCopyMissing(item.localURL.path)
        }
        return ScpTransferJob(
            id: "remote_edit_upload_\(UUID().uuidString)",
            direction: .upload,
            sourcePath: item.localURL.path,
            destinationPath: item.remotePath,
            bytesTotal: localFileSize(at: item.localURL)
        )
    }

    public func uploadJob(for item: RemoteEditCacheItem) throws -> ScpTransferJob {
        try makeUploadJob(for: item)
    }

    public func makeUploadJobsForChangedLocalCopies() throws -> [ScpTransferJob] {
        try changedLocalCopies().map { item in
            try makeUploadJob(for: item)
        }
    }

    public func makeUploadJobsForChangedLocalCopies(runtimeID: String, sessionID: String) throws -> [ScpTransferJob] {
        try changedLocalCopies(runtimeID: runtimeID, sessionID: sessionID).map { item in
            try makeUploadJob(for: item)
        }
    }

    public func localCopyHasChanged(for item: RemoteEditCacheItem) throws -> Bool {
        guard isInsideCache(item.localURL) else {
            throw RemoteEditCacheError.invalidLocalPath
        }
        guard fileManager.fileExists(atPath: item.localURL.path) else {
            throw RemoteEditCacheError.localCopyMissing(item.localURL.path)
        }
        guard let localModifiedAt = localFileModificationDate(at: item.localURL) else {
            return false
        }
        if let cleanLocalModifiedAt = cleanLocalModifiedAtByItemID[item.id] {
            return localModifiedAt.isMeaningfullyAfter(cleanLocalModifiedAt)
        }
        guard let remoteModifiedAt = item.modifiedAt else {
            return false
        }
        return localModifiedAt.isMeaningfullyAfter(remoteModifiedAt)
    }

    public func changedLocalCopies() throws -> [RemoteEditCacheItem] {
        try refreshItemsFromDisk()
        var changedItems: [RemoteEditCacheItem] = []
        for itemID in itemIDsInCreationOrder {
            guard let item = itemsByID[itemID] else {
                continue
            }
            if item.isDirty {
                changedItems.append(item)
            } else if try localCopyHasChanged(for: item) {
                changedItems.append(item)
            }
        }
        return changedItems
    }

    public func changedLocalCopies(runtimeID: String, sessionID: String) throws -> [RemoteEditCacheItem] {
        try refreshItemsFromDisk()
        var changedItems: [RemoteEditCacheItem] = []
        for itemID in itemIDsInCreationOrder {
            guard let item = itemsByID[itemID],
                  item.runtimeID == runtimeID,
                  item.sessionID == sessionID
            else {
                continue
            }
            if item.isDirty {
                changedItems.append(item)
            } else if try localCopyHasChanged(for: item) {
                changedItems.append(item)
            }
        }
        return changedItems
    }

    private func storeTrackedItem(_ item: RemoteEditCacheItem, cleanLocalModifiedAt: Date? = nil) {
        let key = itemKey(remotePath: item.remotePath, runtimeID: item.runtimeID, sessionID: item.sessionID)
        if let existingItemID = itemIDsByKey[key] {
            if existingItemID == item.id {
                itemsByID[item.id] = item
                cleanLocalModifiedAtByItemID[item.id] = cleanLocalModifiedAt
                return
            }
            itemsByID.removeValue(forKey: existingItemID)
            itemIDsInCreationOrder.removeAll { $0 == existingItemID }
            cleanLocalModifiedAtByItemID.removeValue(forKey: existingItemID)
        }
        if itemsByID[item.id] != nil {
            itemsByID[item.id] = item
            cleanLocalModifiedAtByItemID[item.id] = cleanLocalModifiedAt
            return
        }
        itemsByID[item.id] = item
        itemIDsInCreationOrder.append(item.id)
        itemIDsByKey[key] = item.id
        cleanLocalModifiedAtByItemID[item.id] = cleanLocalModifiedAt
    }

    private func refreshItemsFromDisk() throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return
        }
        guard isInsideCache(rootDirectory) else {
            throw RemoteEditCacheError.invalidCacheRoot
        }
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return
        }
        var metadataURLs: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == itemMetadataFileName {
            metadataURLs.append(fileURL)
        }

        for metadataURL in metadataURLs.sorted(by: { $0.path < $1.path }) {
            let scanned: (item: RemoteEditCacheItem, cleanLocalModifiedAt: Date?, shouldPersistDirtyState: Bool)?
            do {
                scanned = try itemFromMetadata(at: metadataURL)
            } catch {
                continue
            }
            guard let scanned else {
                continue
            }
            storeTrackedItem(scanned.item, cleanLocalModifiedAt: scanned.cleanLocalModifiedAt)
            if scanned.shouldPersistDirtyState {
                try writeMetadata(for: scanned.item, cleanLocalModifiedAt: scanned.cleanLocalModifiedAt)
            }
        }
    }

    private func itemFromMetadata(
        at metadataURL: URL
    ) throws -> (item: RemoteEditCacheItem, cleanLocalModifiedAt: Date?, shouldPersistDirtyState: Bool)? {
        guard isInsideCache(metadataURL) else {
            throw RemoteEditCacheError.invalidLocalPath
        }
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let metadata = try decoder.decode(RemoteEditCacheItemMetadata.self, from: data)
        let localURL = metadata.localPath.map { URL(fileURLWithPath: $0, isDirectory: false) }
            ?? metadataURL
                .deletingLastPathComponent()
                .appendingPathComponent(metadata.fileName, isDirectory: false)
        guard isInsideCache(localURL) else {
            throw RemoteEditCacheError.invalidLocalPath
        }
        guard fileManager.fileExists(atPath: localURL.path) else {
            return nil
        }

        let cleanLocalModifiedAt = metadata.cleanLocalModifiedAt
        let localChangedSinceClean: Bool
        if let cleanLocalModifiedAt,
           let localModifiedAt = localFileModificationDate(at: localURL)
        {
            localChangedSinceClean = localModifiedAt.isMeaningfullyAfter(cleanLocalModifiedAt)
        } else {
            localChangedSinceClean = false
        }
        let isDirty = metadata.isDirty || localChangedSinceClean
        let item = RemoteEditCacheItem(
            id: metadata.id,
            runtimeID: metadata.runtimeID,
            sessionID: metadata.sessionID,
            remotePath: metadata.remotePath,
            localURL: localURL,
            fileName: metadata.fileName,
            modifiedAt: metadata.modifiedAt,
            isDirty: isDirty
        )
        return (
            item: item,
            cleanLocalModifiedAt: cleanLocalModifiedAt,
            shouldPersistDirtyState: isDirty && metadata.isDirty == false
        )
    }

    private func writeMetadata(for item: RemoteEditCacheItem, cleanLocalModifiedAt: Date?) throws {
        let metadataURL = metadataURL(for: item)
        guard isInsideCache(metadataURL) else {
            throw RemoteEditCacheError.invalidLocalPath
        }
        try fileManager.createDirectory(
            at: metadataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let metadata = RemoteEditCacheItemMetadata(
            schemaVersion: 1,
            id: item.id,
            runtimeID: item.runtimeID,
            sessionID: item.sessionID,
            remotePath: item.remotePath,
            fileName: item.fileName,
            localPath: item.localURL.path,
            modifiedAt: item.modifiedAt,
            cleanLocalModifiedAt: cleanLocalModifiedAt,
            isDirty: item.isDirty
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
        cleanLocalModifiedAtByItemID[item.id] = cleanLocalModifiedAt
    }

    private func metadataURL(for item: RemoteEditCacheItem) -> URL {
        item.localURL
            .deletingLastPathComponent()
            .appendingPathComponent(itemMetadataFileName, isDirectory: false)
    }

    private func readableFileName(from remotePath: String) -> String {
        let lastPathComponent = (remotePath as NSString).lastPathComponent
        let sanitized = lastPathComponent.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "/", ":", "\0":
                return "_"
            default:
                return Character(scalar)
            }
        }
        let candidate = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || candidate == "." || candidate == ".." {
            return "remote-file"
        }
        return candidate
    }

    private func safeIdentitySegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let collapsed = String(sanitized)
            .split(separator: "_")
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let base = collapsed.isEmpty ? "unknown" : collapsed
        return base == value ? base : "\(base)-\(remotePathFingerprint(value))"
    }

    private func remotePathFingerprint(_ remotePath: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in remotePath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private func itemKey(remotePath: String, runtimeID: String, sessionID: String) -> String {
        "\(safeIdentitySegment(runtimeID))|\(safeIdentitySegment(sessionID))|\(remotePathFingerprint(remotePath))"
    }

    private func isInsideCache(_ url: URL) -> Bool {
        let rootPath = rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func localFileSize(at url: URL) -> UInt64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.uint64Value
    }

    private func trackedItems(where predicate: (RemoteEditCacheItem) -> Bool) -> [RemoteEditCacheItem] {
        itemIDsInCreationOrder.compactMap { itemID in
            guard let item = itemsByID[itemID], predicate(item) else {
                return nil
            }
            return item
        }
    }

    private func removeTrackedItems(where predicate: (RemoteEditCacheItem) -> Bool) {
        let removedItemIDs = Set(trackedItems(where: predicate).map(\.id))
        guard removedItemIDs.isEmpty == false else {
            return
        }
        itemIDsInCreationOrder.removeAll { removedItemIDs.contains($0) }
        itemsByID = itemsByID.filter { !removedItemIDs.contains($0.key) }
        itemIDsByKey = itemIDsByKey.filter { !removedItemIDs.contains($0.value) }
        cleanLocalModifiedAtByItemID = cleanLocalModifiedAtByItemID.filter { !removedItemIDs.contains($0.key) }
    }

    private func sessionDirectories(for sessionID: String) throws -> [URL] {
        var directoriesByPath: [String: URL] = [:]
        for item in trackedItems(where: { $0.sessionID == sessionID }) {
            let directory = rootDirectory
                .appendingPathComponent(safeIdentitySegment(item.runtimeID), isDirectory: true)
                .appendingPathComponent(safeIdentitySegment(item.sessionID), isDirectory: true)
            directoriesByPath[directory.standardizedFileURL.path] = directory
        }
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            return Array(directoriesByPath.values)
        }

        let runtimeDirectories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let sessionSegment = safeIdentitySegment(sessionID)
        for runtimeDirectory in runtimeDirectories where isDirectory(runtimeDirectory) {
            let candidate = runtimeDirectory.appendingPathComponent(sessionSegment, isDirectory: true)
            if sessionDirectory(candidate, matches: sessionID) {
                directoriesByPath[candidate.standardizedFileURL.path] = candidate
            }
        }
        return directoriesByPath.keys.sorted().compactMap { directoriesByPath[$0] }
    }

    private func writeSessionIdentityMarker(_ sessionID: String, in directory: URL) throws {
        let markerURL = directory.appendingPathComponent(sessionIdentityFileName, isDirectory: false)
        try Data(sessionID.utf8).write(to: markerURL, options: .atomic)
    }

    private func sessionDirectory(_ directory: URL, matches sessionID: String) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }
        let markerURL = directory.appendingPathComponent(sessionIdentityFileName, isDirectory: false)
        if let data = try? Data(contentsOf: markerURL),
           let marker = String(data: data, encoding: .utf8) {
            return marker == sessionID
        }
        return directory.lastPathComponent == safeIdentitySegment(sessionID)
    }

    private func directorySize(at directory: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
        }
        guard isInsideCache(directory) else {
            throw RemoteEditCacheError.invalidCacheRoot
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent != sessionIdentityFileName else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += UInt64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func removeCachedItemDirectory(for item: RemoteEditCacheItem) throws {
        let itemDirectory = item.localURL.deletingLastPathComponent()
        guard isInsideCache(itemDirectory) else {
            guard item.id.hasPrefix("remote_edit_test_") else {
                throw RemoteEditCacheError.invalidLocalPath
            }
            if fileManager.fileExists(atPath: item.localURL.path) {
                try fileManager.removeItem(at: item.localURL)
            }
            return
        }
        guard itemDirectory != rootDirectory else {
            throw RemoteEditCacheError.invalidLocalPath
        }
        if fileManager.fileExists(atPath: itemDirectory.path) {
            try fileManager.removeItem(at: itemDirectory)
        } else if fileManager.fileExists(atPath: item.localURL.path) {
            try fileManager.removeItem(at: item.localURL)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func localFileModificationDate(at url: URL) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private func removeEmptyRuntimeDirectory(runtimeID: String) {
        let runtimeDirectory = rootDirectory.appendingPathComponent(safeIdentitySegment(runtimeID), isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: runtimeDirectory, includingPropertiesForKeys: nil),
              enumerator.nextObject() == nil
        else {
            return
        }
        try? fileManager.removeItem(at: runtimeDirectory)
    }
}

extension RemoteEditCache: RemoteEditSessionCacheClearing {}

private extension Date {
    func isMeaningfullyAfter(_ other: Date) -> Bool {
        timeIntervalSince(other) > 0.001
    }
}
