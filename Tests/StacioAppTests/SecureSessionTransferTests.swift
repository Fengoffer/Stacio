import Foundation
import XCTest
@testable import StacioApp
import StacioCoreBindings

final class SecureSessionTransferTests: XCTestCase {
    func testEncryptedTransferDoesNotExposeCredentialAndRoundTrips() throws {
        let payload = SecureSessionTransferPayload(
            sessionJSON: "{\"format\":\"stacio.sessions.v1\",\"sessions\":[{\"name\":\"Production API\"}]}",
            metadata: SecureSessionTransferSessionMetadata(
                name: "Production API",
                protocolName: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy"
            ),
            credential: SecureSessionTransferCredential(kind: .password, secret: "hunter2"),
            privateKey: nil
        )

        let encrypted = try SecureSessionTransfer.encrypt(payload, passphrase: "migration-passphrase")

        XCTAssertTrue(SecureSessionTransfer.isEncryptedTransfer(encrypted))
        XCTAssertFalse(encrypted.contains("hunter2"))
        XCTAssertFalse(encrypted.contains("api.example.com"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encrypted.utf8)) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, "stacio.secure-session.v1")
        XCTAssertNotNil(root["kdf"])
        XCTAssertNotNil(root["cipher"])
        XCTAssertNil(root["credential"])

        let decrypted = try SecureSessionTransfer.decrypt(encrypted, passphrase: "migration-passphrase")

        XCTAssertEqual(decrypted, payload)
        XCTAssertEqual(decrypted.externalCredentialPayload()?.sessions.first?.credential, .password("hunter2"))
    }

    func testEncryptedTransferRejectsWrongPassphrase() throws {
        let payload = SecureSessionTransferPayload(
            sessionJSON: "{}",
            metadata: SecureSessionTransferSessionMetadata(
                name: "API",
                protocolName: "ssh",
                host: "api.example.com",
                port: 22,
                username: "deploy"
            ),
            credential: nil,
            privateKey: nil
        )
        let encrypted = try SecureSessionTransfer.encrypt(payload, passphrase: "correct-passphrase")

        XCTAssertThrowsError(try SecureSessionTransfer.decrypt(encrypted, passphrase: "wrong-passphrase")) { error in
            XCTAssertEqual(error as? SecureSessionTransferError, .decryptionFailed)
        }
    }

    func testKeychainExporterEncryptsCredentialAndKeepsOnlySafeConfig() throws {
        let backend = InMemoryKeychainBackend()
        let keychain = KeychainCredentialStore(backend: backend)
        let credential = CredentialRecord(
            id: "credential_api",
            kind: "password",
            label: "API password",
            keychainService: KeychainCredentialStore.serviceName,
            keychainAccount: "deploy@api.example.com"
        )
        try keychain.save(
            KeychainCredential(
                id: credential.id,
                account: credential.keychainAccount,
                secret: "portable-secret"
            )
        )
        let session = SessionRecord(
            id: "session_api",
            folderId: nil,
            name: "API",
            protocol: "ssh",
            host: "api.example.com",
            port: 22,
            username: "deploy",
            privateKeyPath: nil,
            credentialId: credential.id,
            tags: ["production"],
            lastOpenedAt: nil
        )

        let encrypted = try KeychainSecureSessionTransferExporter(keychainStore: keychain).encryptedTransfer(
            for: session,
            configJSON: ##"{"sessionIconID":"ubuntu","startupCommand":"export TOKEN=hidden"}"##,
            credential: credential,
            passphrase: "migration-passphrase"
        )

        XCTAssertFalse(encrypted.contains("portable-secret"))
        XCTAssertFalse(encrypted.contains("TOKEN"))
        let payload = try SecureSessionTransfer.decrypt(encrypted, passphrase: "migration-passphrase")
        XCTAssertEqual(payload.credential, .init(kind: .password, secret: "portable-secret"))
        XCTAssertTrue(payload.sessionJSON.contains("sessionIconID"))
        XCTAssertFalse(payload.sessionJSON.contains("startupCommand"))
    }

    func testKeychainExporterEncryptsPrivateKeyContents() throws {
        let privateKeyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let privateKeyContents = "-----BEGIN OPENSSH PRIVATE KEY-----\nprivate-key-material\n-----END OPENSSH PRIVATE KEY-----"
        try Data(privateKeyContents.utf8).write(to: privateKeyURL)
        defer { try? FileManager.default.removeItem(at: privateKeyURL) }
        let session = SessionRecord(
            id: "session_key",
            folderId: nil,
            name: "Key Session",
            protocol: "ssh",
            host: "key.example.com",
            port: 22,
            username: "ops",
            privateKeyPath: privateKeyURL.path,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        let encrypted = try KeychainSecureSessionTransferExporter().encryptedTransfer(
            for: session,
            configJSON: nil,
            credential: nil,
            passphrase: "migration-passphrase"
        )

        XCTAssertFalse(encrypted.contains("private-key-material"))
        let payload = try SecureSessionTransfer.decrypt(encrypted, passphrase: "migration-passphrase")
        XCTAssertEqual(payload.privateKey?.fileName, privateKeyURL.lastPathComponent)
        XCTAssertEqual(payload.privateKey?.contents, Data(privateKeyContents.utf8))
    }

    func testPrivateKeyInstallerUsesStacioManagedDirectoryAndRestrictivePermissions() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        var savedPath: String?
        let installer = StacioImportedPrivateKeyInstaller(
            applicationSupportDirectoryProvider: { rootDirectory },
            sessionPathUpdater: { _, _, privateKeyPath in
                savedPath = privateKeyPath
            }
        )
        let session = SessionRecord(
            id: "session_imported",
            folderId: nil,
            name: "Imported key",
            protocol: "ssh",
            host: "key.example.com",
            port: 22,
            username: "ops",
            privateKeyPath: nil,
            credentialId: nil,
            tags: [],
            lastOpenedAt: nil
        )

        try installer.install(
            SecureSessionTransferPrivateKey(
                fileName: "../id_rsa",
                contents: Data("private-key-material".utf8)
            ),
            for: session,
            databasePath: "/tmp/Stacio.sqlite"
        )

        let path = try XCTUnwrap(savedPath)
        XCTAssertTrue(path.contains("ImportedPrivateKeys"))
        XCTAssertFalse(path.hasSuffix("../id_rsa"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("private-key-material".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }
}
