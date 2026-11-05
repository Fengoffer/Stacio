import Foundation

public struct StacioCacheSummary: Equatable, Sendable {
    public let totalBytes: UInt64
    public let dirtyRemoteEditItemCount: Int

    public init(totalBytes: UInt64, dirtyRemoteEditItemCount: Int) {
        self.totalBytes = totalBytes
        self.dirtyRemoteEditItemCount = dirtyRemoteEditItemCount
    }
}

public struct StacioCacheClearResult: Equatable, Sendable {
    public let bytesCleared: UInt64

    public init(bytesCleared: UInt64) {
        self.bytesCleared = bytesCleared
    }
}

public protocol StacioCacheMaintaining: AnyObject {
    func cacheSummary() throws -> StacioCacheSummary
    func clearAllCaches() throws -> StacioCacheClearResult
}

public final class StacioCacheMaintenance: StacioCacheMaintaining {
    private let remoteEditCache: RemoteEditCache
    private let additionalCacheDirectories: [URL]
    private let fileManager: FileManager

    public convenience init(fileManager: FileManager = .default) {
        self.init(
            remoteEditCache: .defaultCache(fileManager: fileManager),
            additionalCacheDirectories: Self.defaultAdditionalCacheDirectories(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    public init(
        remoteEditCache: RemoteEditCache,
        additionalCacheDirectories: [URL],
        fileManager: FileManager = .default
    ) {
        self.remoteEditCache = remoteEditCache
        self.additionalCacheDirectories = additionalCacheDirectories
        self.fileManager = fileManager
    }

    public func cacheSummary() throws -> StacioCacheSummary {
        guard isRemoteEditCacheRoot(remoteEditCache.cacheRootURL) else {
            throw RemoteEditCacheError.invalidCacheRoot
        }
        let additionalBytes = try uniqueAdditionalDirectories().reduce(UInt64(0)) { total, directory in
            try total + directorySize(at: directory)
        }
        return StacioCacheSummary(
            totalBytes: try remoteEditCache.cacheSizeBytes() + additionalBytes,
            dirtyRemoteEditItemCount: remoteEditCache.dirtyItemCount()
        )
    }

    public func clearAllCaches() throws -> StacioCacheClearResult {
        let summary = try cacheSummary()
        try remoteEditCache.clearAll()
        for directory in uniqueAdditionalDirectories() where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        return StacioCacheClearResult(bytesCleared: summary.totalBytes)
    }

    public static func defaultAdditionalCacheDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            fileManager.temporaryDirectory.appendingPathComponent("StacioRemoteFileCreate", isDirectory: true),
            fileManager.temporaryDirectory.appendingPathComponent("StacioRemoteEditCache", isDirectory: true),
            fileManager.temporaryDirectory.appendingPathComponent("StacioRemoteFileCreate", isDirectory: true),
            fileManager.temporaryDirectory.appendingPathComponent("StacioRemoteEditCache", isDirectory: true)
        ]
    }

    private func uniqueAdditionalDirectories() -> [URL] {
        var seen: Set<String> = []
        return additionalCacheDirectories.filter { directory in
            let path = directory.standardizedFileURL.path
            guard seen.contains(path) == false,
                  isStacioOwnedAdditionalCacheDirectory(directory)
            else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private func isRemoteEditCacheRoot(_ directory: URL) -> Bool {
        let candidatePath = directory.standardizedFileURL.path
        let defaultRootPath = RemoteEditCache
            .defaultRootDirectory(fileManager: fileManager)
            .standardizedFileURL
            .path
        if candidatePath == defaultRootPath {
            return true
        }

        guard ["StacioRemoteEditCache", "StacioRemoteEditCache"].contains(directory.lastPathComponent) else {
            return false
        }
        let tempPath = fileManager.temporaryDirectory.standardizedFileURL.path
        return candidatePath == tempPath.appending("/StacioRemoteEditCache")
            || candidatePath == tempPath.appending("/StacioRemoteEditCache")
            || candidatePath.hasPrefix(tempPath + "/")
    }

    private func isStacioOwnedAdditionalCacheDirectory(_ directory: URL) -> Bool {
        let allowedNames = Set([
            "StacioRemoteFileCreate",
            "StacioRemoteEditCache",
            "StacioRemoteFileCreate",
            "StacioRemoteEditCache"
        ])
        guard allowedNames.contains(directory.lastPathComponent) else {
            return false
        }
        let tempPath = fileManager.temporaryDirectory.standardizedFileURL.path
        let candidatePath = directory.standardizedFileURL.path
        return candidatePath == tempPath || candidatePath.hasPrefix(tempPath + "/")
    }

    private func directorySize(at directory: URL) throws -> UInt64 {
        guard fileManager.fileExists(atPath: directory.path) else {
            return 0
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
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += UInt64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
