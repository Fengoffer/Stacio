import Foundation
import StacioCoreBindings

public protocol CredentialCenterManaging {
    func listCredentials() throws -> [CredentialRecord]
    func saveCredential(kind: String, label: String, account: String, secret: String) throws -> CredentialRecord
    func deleteCredential(id: String) throws
}

public struct CoreBridgeCredentialCenterStore: CredentialCenterManaging {
    private let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public static func defaultStore() -> CredentialCenterManaging? {
        guard let databasePath = try? StacioPaths().databaseURL.path else {
            return nil
        }
        return CoreBridgeCredentialCenterStore(databasePath: databasePath)
    }

    public func listCredentials() throws -> [CredentialRecord] {
        try CoreBridge.listCredentialRecords(databasePath: databasePath)
    }

    public func saveCredential(kind: String, label: String, account: String, secret: String) throws -> CredentialRecord {
        try KeychainSessionSidebarCredentialSaver(databasePath: databasePath).saveCredential(
            kind: kind,
            label: label,
            account: account,
            secret: secret
        )
    }

    public func deleteCredential(id: String) throws {
        try CoreBridge.deleteCredentialRecord(databasePath: databasePath, id: id)
    }
}
