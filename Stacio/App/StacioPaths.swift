import Foundation

public struct StacioPaths {
    public static let applicationSupportDirectoryName = "Stacio"
    public static let legacyApplicationSupportDirectoryName = "Stacio"
    public static let migrationMarkerFileName = "MIGRATED_TO_STACIO"

    public let applicationSupportDirectory: URL
    public let databaseURL: URL

    public init(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let directory = try applicationSupportDirectory ?? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(Self.applicationSupportDirectoryName, isDirectory: true)

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        self.applicationSupportDirectory = directory
        databaseURL = directory.appendingPathComponent("Stacio.sqlite")
    }

    public static func agentBridgeSocketPath(fileManager: FileManager = .default) throws -> URL {
        try StacioPaths(fileManager: fileManager)
            .applicationSupportDirectory
            .appendingPathComponent("agent-bridge.sock")
    }

    public static func migrateLegacyApplicationSupportIfNeeded(fileManager: FileManager = .default) throws {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let legacyDirectory = appSupport.appendingPathComponent(legacyApplicationSupportDirectoryName, isDirectory: true)
        let stacioDirectory = appSupport.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
        try migrateLegacyApplicationSupportIfNeeded(
            legacyDirectory: legacyDirectory,
            stacioDirectory: stacioDirectory,
            fileManager: fileManager
        )
    }

    static func migrateLegacyApplicationSupportIfNeeded(
        legacyDirectory: URL,
        stacioDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        var isLegacyDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyDirectory.path, isDirectory: &isLegacyDirectory),
              isLegacyDirectory.boolValue
        else {
            try fileManager.createDirectory(at: stacioDirectory, withIntermediateDirectories: true)
            return
        }

        try fileManager.createDirectory(at: stacioDirectory, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        for sourceURL in contents where sourceURL.lastPathComponent != migrationMarkerFileName {
            let destinationURL = stacioDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            guard fileManager.fileExists(atPath: destinationURL.path) == false else {
                continue
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        let legacyDatabaseURL = legacyDirectory.appendingPathComponent("Stacio.sqlite")
        let stacioDatabaseURL = stacioDirectory.appendingPathComponent("Stacio.sqlite")
        if fileManager.fileExists(atPath: legacyDatabaseURL.path),
           fileManager.fileExists(atPath: stacioDatabaseURL.path) == false
        {
            try fileManager.copyItem(at: legacyDatabaseURL, to: stacioDatabaseURL)
        }

        let markerURL = legacyDirectory.appendingPathComponent(migrationMarkerFileName)
        if fileManager.fileExists(atPath: markerURL.path) == false {
            try Data("Migrated to Stacio. Legacy Stacio directory intentionally retained.\n".utf8)
                .write(to: markerURL, options: .atomic)
        }
    }
}
