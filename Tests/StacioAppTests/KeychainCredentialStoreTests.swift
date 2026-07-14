import XCTest
@testable import StacioApp

final class KeychainCredentialStoreTests: XCTestCase {
    func testBuildsStableCredentialStorageKey() throws {
        let credential = KeychainCredential(
            id: "session-1-password",
            account: "deploy@example.com",
            secret: "super-secret"
        )

        let key = KeychainCredentialStore.storageKey(for: credential.id, account: credential.account)

        XCTAssertEqual(key.service, KeychainCredentialStore.serviceName)
        XCTAssertEqual(key.service, "Stacio")
        XCTAssertEqual(key.account, "deploy@example.com")
        XCTAssertEqual(key.id, "session-1-password")
    }

    func testReadSecretMigratesLegacyServiceCredentialOnDemand() throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let legacyKey = KeychainCredentialStore.legacyStorageKey(
            for: "session-1-password",
            account: "deploy@example.com"
        )
        try backend.save(key: legacyKey, secret: Data("legacy-secret".utf8))

        XCTAssertEqual(
            try store.readSecret(id: "session-1-password", account: "deploy@example.com"),
            "legacy-secret"
        )

        XCTAssertEqual(
            try backend.read(
                key: KeychainCredentialStore.storageKey(
                    for: "session-1-password",
                    account: "deploy@example.com"
                )
            ),
            Data("legacy-secret".utf8)
        )
        XCTAssertEqual(try backend.read(key: legacyKey), Data("legacy-secret".utf8))
    }

    func testStoreCanSaveMultipleCredentialIDsForSameAccount() throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)

        try store.save(
            KeychainCredential(
                id: "credential-one",
                account: "deploy@example.com",
                secret: "first-secret"
            )
        )
        try store.save(
            KeychainCredential(
                id: "credential-two",
                account: "deploy@example.com",
                secret: "second-secret"
            )
        )

        XCTAssertEqual(try store.readSecret(id: "credential-one", account: "deploy@example.com"), "first-secret")
        XCTAssertEqual(try store.readSecret(id: "credential-two", account: "deploy@example.com"), "second-secret")
    }

    func testDeleteRemovesCredentialItem() throws {
        let backend = RecordingDeleteKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)

        try store.delete(id: "credential-one", account: "deploy@example.com")

        XCTAssertEqual(
            backend.deletedKeys,
            [KeychainCredentialStore.storageKey(for: "credential-one", account: "deploy@example.com")]
        )
    }

    func testCredentialDebugDescriptionRedactsSecret() throws {
        let credential = KeychainCredential(
            id: "session-1-password",
            account: "deploy@example.com",
            secret: "super-secret"
        )

        let debug = String(describing: credential)

        XCTAssertTrue(debug.contains("session-1-password"))
        XCTAssertFalse(debug.contains("super-secret"))
    }

    func testInMemoryBackendStoresReadsAndDeletesCredential() throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let credential = KeychainCredential(
            id: "session-1-password",
            account: "deploy@example.com",
            secret: "super-secret"
        )

        try store.save(credential)

        XCTAssertEqual(try store.readSecret(id: credential.id, account: credential.account), "super-secret")

        try store.delete(id: credential.id, account: credential.account)

        XCTAssertThrowsError(try store.readSecret(id: credential.id, account: credential.account)) { error in
            XCTAssertEqual(error as? KeychainCredentialError, .notFound)
        }
    }

    func testStacioFileBackendStoresEncryptedSecretWithoutPlaintext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCredentialVault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = StacioFileCredentialBackend(directoryURL: directory, legacyDirectoryURL: nil)
        let store = KeychainCredentialStore(backend: backend)

        try store.save(
            KeychainCredential(
                id: "session-1-password",
                account: "deploy@example.com",
                secret: "super-secret"
            )
        )

        XCTAssertEqual(
            try store.readSecret(id: "session-1-password", account: "deploy@example.com"),
            "super-secret"
        )
        let vaultBytes = try Data(contentsOf: backend.vaultURL)
        let vaultText = String(data: vaultBytes, encoding: .utf8) ?? ""
        XCTAssertFalse(vaultText.contains("super-secret"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backend.keyURL.path))
    }

    func testStacioFileBackendPersistsAcrossStoreInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCredentialVault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try KeychainCredentialStore(
            backend: StacioFileCredentialBackend(directoryURL: directory, legacyDirectoryURL: nil)
        ).save(
            KeychainCredential(
                id: "session-1-password",
                account: "deploy@example.com",
                secret: "super-secret"
            )
        )

        let reopenedStore = KeychainCredentialStore(
            backend: StacioFileCredentialBackend(directoryURL: directory, legacyDirectoryURL: nil)
        )

        XCTAssertEqual(
            try reopenedStore.readSecret(id: "session-1-password", account: "deploy@example.com"),
            "super-secret"
        )
    }

    func testFileBackendFallsBackToLegacyDirectoryForReads() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioCredentialVault-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stacioDirectory = root.appendingPathComponent("Stacio/CredentialVault", isDirectory: true)
        let legacyDirectory = root
            .appendingPathComponent(["Port", "Desk"].joined(), isDirectory: true)
            .appendingPathComponent("CredentialVault", isDirectory: true)
        let legacyStore = KeychainCredentialStore(
            backend: StacioFileCredentialBackend(directoryURL: legacyDirectory, legacyDirectoryURL: nil)
        )
        try legacyStore.save(
            KeychainCredential(
                id: "session-1-password",
                account: "deploy@example.com",
                secret: "legacy-file-secret"
            )
        )

        let stacioStore = KeychainCredentialStore(
            backend: StacioFileCredentialBackend(
                directoryURL: stacioDirectory,
                legacyDirectoryURL: legacyDirectory
            )
        )

        XCTAssertEqual(
            try stacioStore.readSecret(id: "session-1-password", account: "deploy@example.com"),
            "legacy-file-secret"
        )
    }
}

private final class RecordingDeleteKeychainBackend: KeychainBackend {
    private(set) var deletedKeys: [StacioCredentialStorageKey] = []

    func save(key: StacioCredentialStorageKey, secret: Data) throws {}

    func read(key: StacioCredentialStorageKey) throws -> Data {
        throw KeychainCredentialError.notFound
    }

    func delete(key: StacioCredentialStorageKey) throws {
        deletedKeys.append(key)
    }
}
