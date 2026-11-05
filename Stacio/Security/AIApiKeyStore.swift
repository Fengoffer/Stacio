import Foundation

public protocol AIApiKeyStoring: AnyObject {
    func saveAPIKey(_ apiKey: String, for providerID: UUID) throws
    func readAPIKey(for providerID: UUID) throws -> String?
    func deleteAPIKey(for providerID: UUID) throws
}

public protocol LegacyAIApiKeyReading: AnyObject {
    func readLegacyGlobalAPIKey() throws -> String?
}

public extension AIApiKeyStoring {
    // Legacy callers are kept source-compatible while settings migrate to the scoped provider record.
    func saveAPIKey(_ apiKey: String) throws {
        try saveAPIKey(apiKey, for: legacyCompatibilityProviderID)
    }

    func readAPIKey() throws -> String? {
        try readAPIKey(for: legacyCompatibilityProviderID)
    }

    func deleteAPIKey() throws {
        try deleteAPIKey(for: legacyCompatibilityProviderID)
    }
}

private let legacyCompatibilityProviderID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000002"
)!

public final class NonMigratingAIApiKeyStoreAdapter: AIApiKeyStoring, LegacyAIApiKeyReading {
    private let scopedStore: AIApiKeyStoring

    public init(_ scopedStore: AIApiKeyStoring) {
        self.scopedStore = scopedStore
    }

    public func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {
        try scopedStore.saveAPIKey(apiKey, for: providerID)
    }

    public func readAPIKey(for providerID: UUID) throws -> String? {
        try scopedStore.readAPIKey(for: providerID)
    }

    public func deleteAPIKey(for providerID: UUID) throws {
        try scopedStore.deleteAPIKey(for: providerID)
    }

    public func readLegacyGlobalAPIKey() throws -> String? {
        nil
    }
}

public final class KeychainAIApiKeyStore: AIApiKeyStoring, LegacyAIApiKeyReading {
    private static let legacyCredentialID = "stacio.ai.openai-compatible.api-key"
    private static let legacyAccount = "OpenAI Compatible"

    private let credentialStore: KeychainCredentialStore

    public init(credentialStore: KeychainCredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    static func credentialID(for providerID: UUID) -> String {
        "stacio.ai.provider.\(account(for: providerID)).api-key"
    }

    public func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {
        try credentialStore.save(
            KeychainCredential(
                id: Self.credentialID(for: providerID),
                account: Self.account(for: providerID),
                secret: apiKey
            )
        )
    }

    public func readAPIKey(for providerID: UUID) throws -> String? {
        do {
            return try credentialStore.readSecret(
                id: Self.credentialID(for: providerID),
                account: Self.account(for: providerID)
            )
        } catch KeychainCredentialError.notFound {
            return nil
        }
    }

    public func deleteAPIKey(for providerID: UUID) throws {
        try credentialStore.delete(
            id: Self.credentialID(for: providerID),
            account: Self.account(for: providerID)
        )
    }

    public func readLegacyGlobalAPIKey() throws -> String? {
        do {
            return try credentialStore.readSecret(
                id: Self.legacyCredentialID,
                account: Self.legacyAccount
            )
        } catch KeychainCredentialError.notFound {
            return nil
        }
    }

    private static func account(for providerID: UUID) -> String {
        providerID.uuidString.lowercased()
    }
}
