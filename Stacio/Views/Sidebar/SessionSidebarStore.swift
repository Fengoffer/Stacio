import Foundation
import SQLite3
import StacioCoreBindings

public protocol SessionSidebarStoring {
    func createFolder(parentID: String?, name: String) throws -> SessionFolder
    func renameFolder(id: String, name: String) throws -> SessionFolder
    func deleteFolder(id: String) throws
    func listFolders() throws -> [SessionFolder]
    func listSidebarOrder() throws -> [SessionSidebarOrderItem]
    func listSessions(folderID: String?) throws -> [SessionRecord]
    func loadSnapshot() throws -> SessionSidebarSnapshot
    func createSession(_ draft: SessionDraft) throws -> SessionRecord
    func updateSession(id: String, update: SessionUpdate) throws -> SessionRecord
    func duplicateSession(id: String, targetFolderID: String?) throws -> SessionRecord
    func moveSession(id: String, targetFolderID: String?) throws -> SessionRecord
    func placeSidebarItem(kind: String, id: String, targetFolderID: String?, targetIndex: UInt32) throws
    func exportSessionsJSON() throws -> String
    func exportSessionFolderJSON(folderID: String) throws -> String
    func getSessionConfigJSON(id: String) throws -> String?
    func sessionConfigJSONs(ids: [String]) throws -> [String: String]
    func credentialRecord(id: String) throws -> CredentialRecord?
    func creationDates() throws -> [String: Date]
    func deleteSession(id: String) throws
}

public extension SessionSidebarStoring {
    func sessionConfigJSONs(ids: [String]) throws -> [String: String] {
        [:]
    }

    func credentialRecord(id: String) throws -> CredentialRecord? {
        nil
    }

    func creationDates() throws -> [String: Date] { [:] }
}

public final class CoreBridgeSessionSidebarStore: SessionSidebarStoring {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public func listFolders() throws -> [SessionFolder] {
        try CoreBridge.listSessionFolders(databasePath: databasePath)
    }

    public func listSidebarOrder() throws -> [SessionSidebarOrderItem] {
        try CoreBridge.listSessionSidebarOrder(databasePath: databasePath)
    }

    public func loadSnapshot() throws -> SessionSidebarSnapshot {
        try CoreBridge.loadSessionSidebarSnapshot(databasePath: databasePath)
    }

    public func createFolder(parentID: String?, name: String) throws -> SessionFolder {
        try CoreBridge.createSessionFolder(databasePath: databasePath, parentID: parentID, name: name)
    }

    public func renameFolder(id: String, name: String) throws -> SessionFolder {
        try CoreBridge.renameSessionFolder(databasePath: databasePath, id: id, name: name)
    }

    public func deleteFolder(id: String) throws {
        try CoreBridge.deleteSessionFolder(databasePath: databasePath, id: id)
    }

    public func listSessions(folderID: String?) throws -> [SessionRecord] {
        try CoreBridge.listSessionRecords(databasePath: databasePath, folderID: folderID)
    }

    public func createSession(_ draft: SessionDraft) throws -> SessionRecord {
        try CoreBridge.createSessionRecord(databasePath: databasePath, draft: draft)
    }

    public func updateSession(id: String, update: SessionUpdate) throws -> SessionRecord {
        try CoreBridge.updateSessionRecord(databasePath: databasePath, id: id, update: update)
    }

    public func duplicateSession(id: String, targetFolderID: String?) throws -> SessionRecord {
        try CoreBridge.duplicateSessionRecord(
            databasePath: databasePath,
            id: id,
            targetFolderID: targetFolderID
        )
    }

    public func moveSession(id: String, targetFolderID: String?) throws -> SessionRecord {
        try CoreBridge.moveSessionRecord(
            databasePath: databasePath,
            id: id,
            targetFolderID: targetFolderID
        )
    }

    public func placeSidebarItem(
        kind: String,
        id: String,
        targetFolderID: String?,
        targetIndex: UInt32
    ) throws {
        try CoreBridge.placeSessionSidebarItem(
            databasePath: databasePath,
            kind: kind,
            id: id,
            targetFolderID: targetFolderID,
            targetIndex: targetIndex
        )
    }

    public func exportSessionsJSON() throws -> String {
        try CoreBridge.exportSessionsJSON(databasePath: databasePath)
    }

    public func exportSessionFolderJSON(folderID: String) throws -> String {
        try CoreBridge.exportSessionFolderJSON(databasePath: databasePath, folderID: folderID)
    }

    public func getSessionConfigJSON(id: String) throws -> String? {
        try CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: id)
    }

    public func sessionConfigJSONs(ids: [String]) throws -> [String: String] {
        try ids.reduce(into: [:]) { result, id in
            if let configJSON = try CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: id) {
                result[id] = configJSON
            }
        }
    }

    public func credentialRecord(id: String) throws -> CredentialRecord? {
        try CoreBridge
            .listCredentialRecords(databasePath: databasePath)
            .first(where: { $0.id == id })
    }

    public func creationDates() throws -> [String: Date] {
        try SessionSidebarCreationDateReader(path: databasePath).read()
    }

    public func deleteSession(id: String) throws {
        try CoreBridge.deleteSessionRecord(databasePath: databasePath, id: id)
    }
}

private final class SessionSidebarCreationDateReader {
    private let database: OpaquePointer?

    init(path: String) throws {
        var database: OpaquePointer?
        // SQLite may need to create/update the -shm sidecar while opening a
        // WAL database even for a SELECT-only reader. READWRITE without CREATE
        // keeps this reader mutation-free at the schema level while avoiding
        // SQLITE_CANTOPEN when the sidecar is absent.
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown"
            if let database { sqlite3_close(database) }
            throw NSError(
                domain: "Stacio.SessionSidebar.SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "SQLite open failed: \(message)"]
            )
        }
        self.database = database
    }

    deinit { sqlite3_close(database) }

    func read() throws -> [String: Date] {
        var statement: OpaquePointer?
        let sql = "SELECT id, created_at FROM sessions UNION ALL SELECT id, created_at FROM folders"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error("prepare creation dates")
        }
        defer { sqlite3_finalize(statement) }
        var dates: [String: Date] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let idPointer = sqlite3_column_text(statement, 0),
                      let timestampPointer = sqlite3_column_text(statement, 1)
                else { continue }
                let id = String(cString: idPointer)
                let timestamp = String(cString: timestampPointer)
                if let date = Self.date(from: timestamp) {
                    dates[id] = date
                }
            case SQLITE_DONE:
                return dates
            default:
                throw error("read creation dates")
            }
        }
    }

    private func error(_ action: String) -> NSError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown"
        return NSError(
            domain: "Stacio.SessionSidebar.SQLite",
            code: Int(sqlite3_errcode(database)),
            userInfo: [NSLocalizedDescriptionKey: "SQLite \(action) failed: \(message)"]
        )
    }

    private static func date(from timestamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
}
