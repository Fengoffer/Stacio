import XCTest
@testable import StacioApp
import StacioCoreBindings

final class TunnelLiveSessionStoreTests: XCTestCase {
    func testStoreReplacesClearsAndRedactsLiveSessionContext() {
        let store = TunnelLiveSessionStore()

        XCTAssertNil(store.current())

        store.replace(with: liveContext(host: "first.example.com", secret: .password(value: "super-secret")))
        XCTAssertEqual(store.current()?.config.host, "first.example.com")

        store.replace(
            with: liveContext(
                host: "second.example.com",
                secret: .privateKey(privateKeyPem: "PRIVATE KEY", passphrase: "key-passphrase")
            )
        )

        XCTAssertEqual(store.current()?.config.host, "second.example.com")
        let description = String(describing: store)
        XCTAssertTrue(description.contains("second.example.com"))
        XCTAssertFalse(description.contains("super-secret"))
        XCTAssertFalse(description.contains("PRIVATE KEY"))
        XCTAssertFalse(description.contains("key-passphrase"))

        store.clear()
        XCTAssertNil(store.current())
    }
}

private func liveContext(host: String, secret: SshAuthSecret) -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: host,
            port: 22,
            username: "deploy",
            authMethod: .password(credentialRef: "password-ref"),
            connectTimeoutMs: 10_000
        ),
        secret: secret,
        expectedFingerprintSHA256: "SHA256:test"
    )
}
