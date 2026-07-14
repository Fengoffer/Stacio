import Foundation
import StacioCoreBindings

public protocol SessionSidebarStoring {
    func createFolder(parentID: String?, name: String) throws -> SessionFolder
    func renameFolder(id: String, name: String) throws -> SessionFolder
    func deleteFolder(id: String) throws
    func listFolders() throws -> [SessionFolder]
    func listSessions(folderID: String?) throws -> [SessionRecord]
    func createSession(_ draft: SessionDraft) throws -> SessionRecord
    func updateSession(id: String, update: SessionUpdate) throws -> SessionRecord
    func duplicateSession(id: String, targetFolderID: String?) throws -> SessionRecord
    func moveSession(id: String, targetFolderID: String?) throws -> SessionRecord
    func exportSessionsJSON() throws -> String
    func exportSessionFolderJSON(folderID: String) throws -> String
    func getSessionConfigJSON(id: String) throws -> String?
    func deleteSession(id: String) throws
}

public final class CoreBridgeSessionSidebarStore: SessionSidebarStoring {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public func listFolders() throws -> [SessionFolder] {
        try CoreBridge.listSessionFolders(databasePath: databasePath)
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

    public func exportSessionsJSON() throws -> String {
        try CoreBridge.exportSessionsJSON(databasePath: databasePath)
    }

    public func exportSessionFolderJSON(folderID: String) throws -> String {
        try CoreBridge.exportSessionFolderJSON(databasePath: databasePath, folderID: folderID)
    }

    public func getSessionConfigJSON(id: String) throws -> String? {
        try CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: id)
    }

    public func deleteSession(id: String) throws {
        try CoreBridge.deleteSessionRecord(databasePath: databasePath, id: id)
    }
}
