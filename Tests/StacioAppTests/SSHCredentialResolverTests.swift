import XCTest
@testable import StacioApp
import StacioCoreBindings

final class SSHCredentialResolverTests: XCTestCase {
    func testResolvesPasswordCredentialReference() throws {
        let store = seededStore(id: "password-ref", account: "deploy@example.com", secret: "super-secret")
        let resolver = SSHCredentialResolver(store: store)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .password(credentialRef: "password-ref"),
            connectTimeoutMs: 10_000
        )

        let credential = try resolver.resolve(config)

        XCTAssertEqual(credential.kind, .password)
        XCTAssertEqual(credential.primarySecret, "super-secret")
        XCTAssertFalse(String(describing: credential).contains("super-secret"))
    }

    func testResolvesPrivateKeyPassphraseReference() throws {
        let store = seededStore(id: "passphrase-ref", account: "deploy@example.com", secret: "key-passphrase")
        let resolver = SSHCredentialResolver(store: store)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .privateKey(
                keyPath: "/Users/me/.ssh/id_ed25519",
                passphraseRef: "passphrase-ref"
            ),
            connectTimeoutMs: 10_000
        )

        let credential = try resolver.resolve(config)

        XCTAssertEqual(credential.kind, .privateKeyPassphrase)
        XCTAssertEqual(credential.primarySecret, "key-passphrase")
        XCTAssertFalse(String(describing: credential).contains("key-passphrase"))
        XCTAssertFalse(String(describing: credential).contains("/Users/me/.ssh/id_ed25519"))
    }

    func testAgentAuthDoesNotReadKeychain() throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        let resolver = SSHCredentialResolver(store: store)
        let config = SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        )

        let credential = try resolver.resolve(config)

        XCTAssertEqual(credential.kind, .agent)
        XCTAssertNil(credential.primarySecret)
    }

    private func seededStore(id: String, account: String, secret: String) -> KeychainCredentialStore {
        let backend = InMemoryKeychainBackend()
        let store = KeychainCredentialStore(backend: backend)
        try! store.save(KeychainCredential(id: id, account: account, secret: secret))
        return store
    }
}
