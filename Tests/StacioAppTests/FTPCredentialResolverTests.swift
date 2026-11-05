import XCTest
@testable import StacioApp
import StacioCoreBindings

final class FTPCredentialResolverTests: XCTestCase {
    func testAnonymousUserUsesImportedPasswordCredentialWhenPresent() throws {
        let store = KeychainCredentialStore(backend: InMemoryKeychainBackend())
        try store.save(
            KeychainCredential(
                id: "anonymous-password",
                account: "anonymous@ftp.example.com",
                secret: "user@example.com"
            )
        )
        let resolver = FTPCredentialResolver(store: store)

        let context = try resolver.resolve(session: session(credentialID: "anonymous-password"))

        XCTAssertEqual(context.config.username, "anonymous")
        XCTAssertEqual(context.secret, .password(value: "user@example.com"))
    }

    func testAnonymousUserWithoutCredentialUsesAnonymousFallback() throws {
        let resolver = FTPCredentialResolver(
            store: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )

        let context = try resolver.resolve(session: session(credentialID: nil))

        XCTAssertEqual(context.secret, .anonymous)
    }

    func testUsesAndConsumesTransientPasswordCredential() throws {
        let resolver = FTPCredentialResolver(
            store: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )
        let credentialID = TransientSSHCredentialStore.shared.store(password: "one-time-ftp")

        let context = try resolver.resolve(session: session(credentialID: credentialID))

        XCTAssertEqual(context.secret, .password(value: "one-time-ftp"))
        XCTAssertNil(TransientSSHCredentialStore.shared.password(for: credentialID))
    }

    func testNamedUserWithoutCredentialUsesEmptyPassword() throws {
        let resolver = FTPCredentialResolver(
            store: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )

        let context = try resolver.resolve(session: session(username: "deploy", credentialID: nil))

        XCTAssertEqual(context.config.username, "deploy")
        XCTAssertEqual(context.secret, .password(value: ""))
    }

    private func session(username: String = "anonymous", credentialID: String?) -> SessionRecord {
        SessionRecord(
            id: "session_ftp",
            folderId: nil,
            name: "Anonymous FTP",
            protocol: "ftp",
            host: "ftp.example.com",
            port: 21,
            username: username,
            privateKeyPath: nil,
            credentialId: credentialID,
            tags: [],
            lastOpenedAt: nil
        )
    }
}
