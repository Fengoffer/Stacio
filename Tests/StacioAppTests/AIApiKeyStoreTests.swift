import Foundation
import XCTest
@testable import StacioApp

final class AIApiKeyStoreTests: XCTestCase {
    private let providerA = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let providerB = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testProviderUUIDsUseIsolatedStableCredentials() throws {
        let backend = InMemoryKeychainBackend()
        let store = KeychainAIApiKeyStore(
            credentialStore: KeychainCredentialStore(backend: backend)
        )

        try store.saveAPIKey("alpha-secret", for: providerA)
        try store.saveAPIKey("beta-secret", for: providerB)

        XCTAssertEqual(try store.readAPIKey(for: providerA), "alpha-secret")
        XCTAssertEqual(try store.readAPIKey(for: providerB), "beta-secret")
        XCTAssertEqual(
            try backend.read(key: expectedStorageKey(for: providerA)),
            Data("alpha-secret".utf8)
        )
        XCTAssertEqual(
            try backend.read(key: expectedStorageKey(for: providerB)),
            Data("beta-secret".utf8)
        )
    }

    func testScopedReadDoesNotReturnLegacyGlobalAPIKey() throws {
        let backend = InMemoryKeychainBackend()
        let credentialStore = KeychainCredentialStore(backend: backend)
        let store = KeychainAIApiKeyStore(credentialStore: credentialStore)
        try credentialStore.save(
            KeychainCredential(
                id: "stacio.ai.openai-compatible.api-key",
                account: "OpenAI Compatible",
                secret: "legacy-global-secret"
            )
        )

        XCTAssertNil(try store.readAPIKey(for: providerA))
    }

    func testScopedDeleteLeavesOtherProviderAndLegacyGlobalCredentials() throws {
        let backend = InMemoryKeychainBackend()
        let credentialStore = KeychainCredentialStore(backend: backend)
        let store = KeychainAIApiKeyStore(credentialStore: credentialStore)
        try store.saveAPIKey("alpha-secret", for: providerA)
        try store.saveAPIKey("beta-secret", for: providerB)
        try credentialStore.save(
            KeychainCredential(
                id: "stacio.ai.openai-compatible.api-key",
                account: "OpenAI Compatible",
                secret: "legacy-global-secret"
            )
        )

        try store.deleteAPIKey(for: providerA)

        XCTAssertNil(try store.readAPIKey(for: providerA))
        XCTAssertEqual(try store.readAPIKey(for: providerB), "beta-secret")
        XCTAssertEqual(try store.readLegacyGlobalAPIKey(), "legacy-global-secret")
    }

    func testExplicitLegacyGlobalReadReturnsStoredCredential() throws {
        let backend = InMemoryKeychainBackend()
        let credentialStore = KeychainCredentialStore(backend: backend)
        let store = KeychainAIApiKeyStore(credentialStore: credentialStore)
        try credentialStore.save(
            KeychainCredential(
                id: "stacio.ai.openai-compatible.api-key",
                account: "OpenAI Compatible",
                secret: "legacy-global-secret"
            )
        )

        XCTAssertEqual(try store.readLegacyGlobalAPIKey(), "legacy-global-secret")
    }

    func testExplicitLegacyGlobalReadReturnsNilWhenCredentialIsMissing() throws {
        let store = KeychainAIApiKeyStore(
            credentialStore: KeychainCredentialStore(backend: InMemoryKeychainBackend())
        )

        XCTAssertNil(try store.readLegacyGlobalAPIKey())
    }

    private func expectedStorageKey(for providerID: UUID) -> StacioCredentialStorageKey {
        let account = providerID.uuidString.lowercased()
        return KeychainCredentialStore.storageKey(
            for: "stacio.ai.provider.\(account).api-key",
            account: account
        )
    }
}
