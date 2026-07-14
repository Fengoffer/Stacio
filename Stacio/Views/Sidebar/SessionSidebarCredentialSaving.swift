import Foundation
import StacioCoreBindings

public protocol SessionSidebarCredentialSaving {
    func saveCredential(
        kind: String,
        label: String,
        account: String,
        secret: String
    ) throws -> CredentialRecord
}

public protocol SessionSidebarCredentialCleaning {
    func cleanupReplacedCredential(previousCredentialID: String?, replacementCredentialID: String?) throws
}

public final class KeychainSessionSidebarCredentialSaver: SessionSidebarCredentialSaving, SessionSidebarCredentialCleaning {
    private let databasePath: String
    private let keychainStore: KeychainCredentialStore

    public init(
        databasePath: String,
        keychainStore: KeychainCredentialStore = KeychainCredentialStore()
    ) {
        self.databasePath = databasePath
        self.keychainStore = keychainStore
    }

    public func saveCredential(
        kind: String,
        label: String,
        account: String,
        secret: String
    ) throws -> CredentialRecord {
        let record = try CoreBridge.saveCredentialRecord(
            databasePath: databasePath,
            draft: CredentialDraft(
                kind: kind,
                label: label,
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: account
            )
        )
        do {
            try keychainStore.save(
                KeychainCredential(
                    id: record.id,
                    account: account,
                    secret: secret
                )
            )
        } catch {
            try? CoreBridge.deleteCredentialRecord(databasePath: databasePath, id: record.id)
            throw error
        }
        return record
    }

    public func cleanupReplacedCredential(previousCredentialID: String?, replacementCredentialID: String?) throws {
        guard let previousCredentialID = optionalTrimmed(previousCredentialID),
              previousCredentialID != optionalTrimmed(replacementCredentialID)
        else {
            return
        }

        let sessions = try CoreBridge.listAllSessionRecords(databasePath: databasePath)
        guard sessions.allSatisfy({ optionalTrimmed($0.credentialId) != previousCredentialID }) else {
            return
        }
        guard let credential = try CoreBridge
            .listCredentialRecords(databasePath: databasePath)
            .first(where: { $0.id == previousCredentialID })
        else {
            return
        }

        try keychainStore.delete(id: credential.id, account: credential.keychainAccount)
        try CoreBridge.deleteCredentialRecord(databasePath: databasePath, id: credential.id)
    }

    private func optionalTrimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
