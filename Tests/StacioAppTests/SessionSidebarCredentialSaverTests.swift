import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class SessionSidebarCredentialSaverTests: XCTestCase {
    func testCredentialSaverStoresSecretInKeychainAndMetadataInCore() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainBackend = InMemoryKeychainBackend()
        let keychainStore = KeychainCredentialStore(backend: keychainBackend)
        let saver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )

        let record = try saver.saveCredential(
            kind: "password",
            label: "API password",
            account: "deploy@example.com",
            secret: "super-secret"
        )

        XCTAssertEqual(try keychainStore.readSecret(id: record.id, account: "deploy@example.com"), "super-secret")
        XCTAssertEqual(try CoreBridge.listCredentialRecords(databasePath: tempURL.path), [record])
        XCTAssertFalse(String(describing: record).contains("super-secret"))
    }

    func testCredentialSaverRollsBackMetadataWhenKeychainSaveFails() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainStore = KeychainCredentialStore(backend: FailingKeychainBackend())
        let saver = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )

        XCTAssertThrowsError(
            try saver.saveCredential(
                kind: "password",
                label: "API password",
                account: "deploy@example.com",
                secret: "super-secret"
            )
        )

        XCTAssertEqual(try CoreBridge.listCredentialRecords(databasePath: tempURL.path), [])
    }

    func testCredentialCleanerDeletesOldCredentialWhenNoSessionsReferenceIt() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainBackend = InMemoryKeychainBackend()
        let keychainStore = KeychainCredentialStore(backend: keychainBackend)
        let oldCredential = try saveCredentialMetadata(
            databasePath: tempURL.path,
            account: "deploy@old.example.com"
        )
        try keychainStore.save(
            KeychainCredential(
                id: oldCredential.id,
                account: oldCredential.keychainAccount,
                secret: "old-secret"
            )
        )
        let newCredential = try saveCredentialMetadata(
            databasePath: tempURL.path,
            account: "deploy@new.example.com"
        )
        let session = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "old.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: oldCredential.id,
                tags: [],
                configJson: nil
            )
        )
        _ = try CoreBridge.updateSessionRecord(
            databasePath: tempURL.path,
            id: session.id,
            update: SessionUpdate(
                name: "API",
                protocol: nil,
                folderId: nil,
                host: "new.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: "",
                credentialId: newCredential.id,
                tags: [],
                configJson: nil
            )
        )
        let cleaner = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )

        try cleaner.cleanupReplacedCredential(
            previousCredentialID: oldCredential.id,
            replacementCredentialID: newCredential.id
        )

        XCTAssertEqual(try CoreBridge.listCredentialRecords(databasePath: tempURL.path).map(\.id), [newCredential.id])
        XCTAssertThrowsError(try keychainStore.readSecret(id: oldCredential.id, account: oldCredential.keychainAccount)) { error in
            XCTAssertEqual(error as? KeychainCredentialError, .notFound)
        }
    }

    func testCredentialCleanerKeepsOldCredentialWhenAnotherSessionReferencesIt() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let keychainBackend = InMemoryKeychainBackend()
        let keychainStore = KeychainCredentialStore(backend: keychainBackend)
        let oldCredential = try saveCredentialMetadata(
            databasePath: tempURL.path,
            account: "deploy@shared.example.com"
        )
        try keychainStore.save(
            KeychainCredential(
                id: oldCredential.id,
                account: oldCredential.keychainAccount,
                secret: "old-secret"
            )
        )
        let newCredential = try saveCredentialMetadata(
            databasePath: tempURL.path,
            account: "deploy@new.example.com"
        )
        let firstSession = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "API",
                protocol: "ssh",
                host: "shared.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: oldCredential.id,
                tags: [],
                configJson: nil
            )
        )
        _ = try CoreBridge.createSessionRecord(
            databasePath: tempURL.path,
            draft: SessionDraft(
                folderId: nil,
                name: "Worker",
                protocol: "ssh",
                host: "shared.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: nil,
                credentialId: oldCredential.id,
                tags: [],
                configJson: nil
            )
        )
        _ = try CoreBridge.updateSessionRecord(
            databasePath: tempURL.path,
            id: firstSession.id,
            update: SessionUpdate(
                name: "API",
                protocol: nil,
                folderId: nil,
                host: "new.example.com",
                port: 22,
                username: "deploy",
                privateKeyPath: "",
                credentialId: newCredential.id,
                tags: [],
                configJson: nil
            )
        )
        let cleaner = KeychainSessionSidebarCredentialSaver(
            databasePath: tempURL.path,
            keychainStore: keychainStore
        )

        try cleaner.cleanupReplacedCredential(
            previousCredentialID: oldCredential.id,
            replacementCredentialID: newCredential.id
        )

        XCTAssertEqual(
            Set(try CoreBridge.listCredentialRecords(databasePath: tempURL.path).map(\.id)),
            Set([oldCredential.id, newCredential.id])
        )
        XCTAssertEqual(
            try keychainStore.readSecret(id: oldCredential.id, account: oldCredential.keychainAccount),
            "old-secret"
        )
    }

    func testDraftFactoryStoresPasswordSecretAndReturnsCredentialReference() throws {
        let saver = RecordingSessionSidebarCredentialSaver(
            nextRecord: CredentialRecord(
                id: "cred_password",
                kind: "password",
                label: "API password",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@api.example.com"
            )
        )
        let factory = SessionSidebarSessionDraftFactory(
            credentialSaver: saver,
            defaultUsername: { "local" }
        )

        let draft = try XCTUnwrap(
            try factory.makeDraft(
                existingSession: nil,
                selectedFolderID: "folder_prod",
                values: SessionSidebarSessionFormValues(
                    name: " API ",
                    host: " api.example.com ",
                    port: " 2222 ",
                    username: " deploy ",
                    authMode: .password,
                    privateKeyPath: "",
                    credentialSecret: "super-secret",
                    tags: " prod, api "
                )
            )
        )

        XCTAssertEqual(draft.folderId, "folder_prod")
        XCTAssertEqual(draft.privateKeyPath, nil)
        XCTAssertEqual(draft.credentialId, "cred_password")
        XCTAssertEqual(saver.requests.map(\.kind), ["password"])
        XCTAssertEqual(saver.requests.map(\.label), ["API password"])
        XCTAssertEqual(saver.requests.map(\.account), ["deploy@api.example.com"])
        XCTAssertEqual(saver.requests.map(\.secret), ["super-secret"])
        XCTAssertFalse(String(describing: draft).contains("super-secret"))
    }

    func testDraftFactoryStoresPrivateKeyPassphraseAndReturnsCredentialReference() throws {
        let saver = RecordingSessionSidebarCredentialSaver(
            nextRecord: CredentialRecord(
                id: "cred_passphrase",
                kind: "private_key_passphrase",
                label: "API private key passphrase",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@api.example.com"
            )
        )
        let factory = SessionSidebarSessionDraftFactory(
            credentialSaver: saver,
            defaultUsername: { "local" }
        )

        let draft = try XCTUnwrap(
            try factory.makeDraft(
                existingSession: nil,
                selectedFolderID: nil,
                values: SessionSidebarSessionFormValues(
                    name: "API",
                    host: "api.example.com",
                    port: "22",
                    username: "deploy",
                    authMode: .privateKey,
                    privateKeyPath: " ~/.ssh/prod ",
                    credentialSecret: "key-passphrase",
                    tags: ""
                )
            )
        )

        XCTAssertEqual(draft.privateKeyPath, "~/.ssh/prod")
        XCTAssertEqual(draft.credentialId, "cred_passphrase")
        XCTAssertEqual(saver.requests.map(\.kind), ["private_key_passphrase"])
        XCTAssertEqual(saver.requests.map(\.label), ["API private key passphrase"])
        XCTAssertEqual(saver.requests.map(\.account), ["deploy@api.example.com"])
        XCTAssertEqual(saver.requests.map(\.secret), ["key-passphrase"])
        XCTAssertFalse(String(describing: draft).contains("key-passphrase"))
    }

    func testDraftFactoryAllowsPasswordModeWithoutUsernameOrPassword() throws {
        let saver = RecordingSessionSidebarCredentialSaver(
            nextRecord: CredentialRecord(
                id: "unused",
                kind: "password",
                label: "unused",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@api.example.com"
            )
        )
        let factory = SessionSidebarSessionDraftFactory(
            credentialSaver: saver,
            defaultUsername: { "local" }
        )

        let draft = try factory.makeDraft(
            existingSession: nil,
            selectedFolderID: nil,
            values: SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )

        XCTAssertEqual(draft?.username, nil)
        XCTAssertEqual(draft?.credentialId, nil)
        XCTAssertTrue(saver.requests.isEmpty)
    }

    func testDraftFactoryPreservesExistingPasswordCredentialWhenSecretBlank() throws {
        let existing = SessionRecord(
            id: "session_api",
            folderId: "folder_prod",
            name: "API",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: "cred_existing",
            tags: [],
            lastOpenedAt: nil
        )
        let saver = RecordingSessionSidebarCredentialSaver(
            nextRecord: CredentialRecord(
                id: "unused",
                kind: "password",
                label: "unused",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@api.example.com"
            )
        )
        let factory = SessionSidebarSessionDraftFactory(
            credentialSaver: saver,
            defaultUsername: { "local" }
        )

        let draft = try XCTUnwrap(
            try factory.makeDraft(
                existingSession: existing,
                selectedFolderID: nil,
                values: SessionSidebarSessionFormValues(
                    name: "API",
                    host: "api.example.com",
                    port: "22",
                    username: "deploy",
                    authMode: .password,
                    privateKeyPath: "",
                    credentialSecret: "",
                    tags: ""
                )
            )
        )

        XCTAssertEqual(draft.folderId, "folder_prod")
        XCTAssertEqual(draft.credentialId, "cred_existing")
        XCTAssertTrue(saver.requests.isEmpty)
    }

    func testDraftFactoryDropsExistingPasswordCredentialWhenAccountChangesAndPasswordIsBlank() throws {
        let existing = SessionRecord(
            id: "session_api",
            folderId: "folder_prod",
            name: "API",
            protocol: "ssh",
            host: "old.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: "cred_existing",
            tags: [],
            lastOpenedAt: nil
        )
        let saver = RecordingSessionSidebarCredentialSaver(
            nextRecord: CredentialRecord(
                id: "unused",
                kind: "password",
                label: "unused",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@new.example.com"
            )
        )
        let factory = SessionSidebarSessionDraftFactory(
            credentialSaver: saver,
            defaultUsername: { "local" }
        )

        let draft = try factory.makeDraft(
            existingSession: existing,
            selectedFolderID: nil,
            values: SessionSidebarSessionFormValues(
                name: "API",
                host: "new.example.com",
                port: "22",
                username: "deploy",
                authMode: .password,
                privateKeyPath: "",
                credentialSecret: "",
                tags: ""
            )
        )

        XCTAssertEqual(draft?.credentialId, nil)
        XCTAssertTrue(saver.requests.isEmpty)
    }

    func testDraftFactoryRequiresNewPrivateKeyPassphraseWhenAccountChanges() throws {
        let existing = SessionRecord(
            id: "session_api",
            folderId: "folder_prod",
            name: "API",
            protocol: "ssh",
            host: "old.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: "/keys/prod",
            credentialId: "cred_existing",
            tags: [],
            lastOpenedAt: nil
        )
        let saver = RecordingSessionSidebarCredentialSaver(
            nextRecord: CredentialRecord(
                id: "unused",
                kind: "private_key_passphrase",
                label: "unused",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@new.example.com"
            )
        )
        let factory = SessionSidebarSessionDraftFactory(
            credentialSaver: saver,
            defaultUsername: { "local" }
        )

        let draft = try factory.makeDraft(
            existingSession: existing,
            selectedFolderID: nil,
            values: SessionSidebarSessionFormValues(
                name: "API",
                host: "new.example.com",
                port: "22",
                username: "deploy",
                authMode: .privateKey,
                privateKeyPath: "/keys/prod",
                credentialSecret: "",
                tags: ""
            )
        )

        XCTAssertNil(draft)
        XCTAssertTrue(saver.requests.isEmpty)
    }

    func testDraftFactoryDoesNotSavePrivateKeyPassphraseWhenKeyPathIsMissing() throws {
        let saver = RecordingSessionSidebarCredentialSaver(
            nextRecord: CredentialRecord(
                id: "unused",
                kind: "private_key_passphrase",
                label: "unused",
                keychainService: KeychainCredentialStore.serviceName,
                keychainAccount: "deploy@api.example.com"
            )
        )
        let factory = SessionSidebarSessionDraftFactory(
            credentialSaver: saver,
            defaultUsername: { "local" }
        )

        let draft = try factory.makeDraft(
            existingSession: nil,
            selectedFolderID: nil,
            values: SessionSidebarSessionFormValues(
                name: "API",
                host: "api.example.com",
                port: "22",
                username: "deploy",
                authMode: .privateKey,
                privateKeyPath: "",
                credentialSecret: "key-passphrase",
                tags: ""
            )
        )

        XCTAssertNil(draft)
        XCTAssertTrue(saver.requests.isEmpty)
    }
}

private final class RecordingSessionSidebarCredentialSaver: SessionSidebarCredentialSaving {
    struct Request {
        let kind: String
        let label: String
        let account: String
        let secret: String
    }

    var requests: [Request] = []
    private let nextRecord: CredentialRecord

    init(nextRecord: CredentialRecord) {
        self.nextRecord = nextRecord
    }

    func saveCredential(
        kind: String,
        label: String,
        account: String,
        secret: String
    ) throws -> CredentialRecord {
        requests.append(
            Request(
                kind: kind,
                label: label,
                account: account,
                secret: secret
            )
        )
        return nextRecord
    }
}

private final class FailingKeychainBackend: KeychainBackend {
    func save(key: StacioCredentialStorageKey, secret: Data) throws {
        throw KeychainCredentialError.accessDenied(-50)
    }

    func read(key: StacioCredentialStorageKey) throws -> Data {
        throw KeychainCredentialError.notFound
    }

    func delete(key: StacioCredentialStorageKey) throws {}
}

private func saveCredentialMetadata(databasePath: String, account: String) throws -> CredentialRecord {
    try CoreBridge.saveCredentialRecord(
        databasePath: databasePath,
        draft: CredentialDraft(
            kind: "password",
            label: "\(account) password",
            keychainService: KeychainCredentialStore.serviceName,
            keychainAccount: account
        )
    )
}
