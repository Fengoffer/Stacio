import Foundation

public enum AIProviderAPIKeyUpdate: Equatable {
    case unchanged
    case replace(String)
    case remove
}

public struct AIProviderConfigurationTransactionError: LocalizedError {
    public let primaryError: Error
    public let rollbackError: Error?

    public init(primaryError: Error, rollbackError: Error? = nil) {
        self.primaryError = primaryError
        self.rollbackError = rollbackError
    }

    public var errorDescription: String? {
        if rollbackError == nil {
            return "The AI provider configuration transaction failed."
        }
        return "The AI provider configuration transaction and credential rollback both failed."
    }
}

public protocol AIProviderMutationCoordinating: AnyObject {
    func saveProvider(
        _ provider: AIProviderConfiguration,
        apiKeyUpdate: AIProviderAPIKeyUpdate
    ) throws -> AIProviderSettingsEnvelope

    func deleteProvider(id: UUID) throws -> AIProviderSettingsEnvelope
    func setDefaultProvider(id: UUID) throws -> AIProviderSettingsEnvelope
    func readAPIKey(for providerID: UUID) throws -> String?
}

public final class AIProviderConfigurationCoordinator: AIProviderMutationCoordinating {
    private static let transactionLock = NSRecursiveLock()

    private enum CredentialRollback {
        case none
        case restore(String)
        case delete
    }

    private let settingsStore: AIProviderSettingsStoring
    private let keyStore: AIApiKeyStoring & LegacyAIApiKeyReading

    public init(
        settingsStore: AIProviderSettingsStoring,
        keyStore: AIApiKeyStoring & LegacyAIApiKeyReading
    ) {
        self.settingsStore = settingsStore
        self.keyStore = keyStore
    }

    public func saveProvider(
        _ provider: AIProviderConfiguration,
        apiKeyUpdate: AIProviderAPIKeyUpdate
    ) throws -> AIProviderSettingsEnvelope {
        try Self.withSharedTransaction {
            var envelope = try settingsStore.loadAIProviderSettings()
            let credentialRollback = try apply(apiKeyUpdate, providerID: provider.id)

            if let index = envelope.aiProviders.firstIndex(where: { $0.id == provider.id }) {
                envelope.aiProviders[index] = provider
            } else {
                envelope.aiProviders.append(provider)
            }
            switch apiKeyUpdate {
            case .unchanged:
                break
            case .replace, .remove:
                if envelope.legacyKeyMigrationProviderID == provider.id {
                    envelope.legacyKeyMigrationProviderID = nil
                }
            }

            let normalized = AIProviderSettingsNormalizer.normalized(envelope)
            do {
                try settingsStore.saveAIProviderSettings(normalized)
            } catch {
                try rollbackThenThrow(
                    primaryError: error,
                    rollback: credentialRollback,
                    providerID: provider.id
                )
            }
            return normalized
        }
    }

    public func deleteProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        try Self.withSharedTransaction {
            var envelope = AIProviderSettingsNormalizer.normalized(
                try settingsStore.loadAIProviderSettings()
            )
            guard id != BuiltInAIProvider.mozheAPIID else {
                return envelope
            }
            let oldAPIKey = try keyStore.readAPIKey(for: id)
            try keyStore.deleteAPIKey(for: id)
            envelope.aiProviders.removeAll { $0.id == id }
            let normalized = AIProviderSettingsNormalizer.normalized(envelope)

            do {
                try settingsStore.saveAIProviderSettings(normalized)
            } catch {
                guard let oldAPIKey else {
                    throw error
                }
                try rollbackThenThrow(
                    primaryError: error,
                    rollback: .restore(oldAPIKey),
                    providerID: id
                )
            }
            return normalized
        }
    }

    public func setDefaultProvider(id: UUID) throws -> AIProviderSettingsEnvelope {
        try Self.withSharedTransaction {
            var envelope = try settingsStore.loadAIProviderSettings()
            envelope.defaultAIProviderID = id
            let normalized = AIProviderSettingsNormalizer.normalized(envelope)
            try settingsStore.saveAIProviderSettings(normalized)
            return normalized
        }
    }

    public func readAPIKey(for providerID: UUID) throws -> String? {
        try Self.withSharedTransaction {
            let envelope = try settingsStore.loadAIProviderSettings()
            if let scopedAPIKey = try keyStore.readAPIKey(for: providerID) {
                if envelope.legacyKeyMigrationProviderID == providerID {
                    var migratedEnvelope = envelope
                    migratedEnvelope.legacyKeyMigrationProviderID = nil
                    let normalized = AIProviderSettingsNormalizer.normalized(migratedEnvelope)
                    try settingsStore.saveAIProviderSettings(normalized)
                }
                return scopedAPIKey
            }
            guard envelope.legacyKeyMigrationProviderID == providerID,
                  let legacyAPIKey = try keyStore.readLegacyGlobalAPIKey()
            else {
                return nil
            }

            try keyStore.saveAPIKey(legacyAPIKey, for: providerID)
            var migratedEnvelope = envelope
            migratedEnvelope.legacyKeyMigrationProviderID = nil
            let normalized = AIProviderSettingsNormalizer.normalized(migratedEnvelope)
            do {
                try settingsStore.saveAIProviderSettings(normalized)
            } catch {
                try rollbackThenThrow(
                    primaryError: error,
                    rollback: .delete,
                    providerID: providerID
                )
            }
            return legacyAPIKey
        }
    }

    private func apply(
        _ update: AIProviderAPIKeyUpdate,
        providerID: UUID
    ) throws -> CredentialRollback {
        switch update {
        case .unchanged:
            return .none
        case let .replace(apiKey):
            let oldAPIKey = try keyStore.readAPIKey(for: providerID)
            try keyStore.saveAPIKey(apiKey, for: providerID)
            if let oldAPIKey {
                return .restore(oldAPIKey)
            }
            return .delete
        case .remove:
            let oldAPIKey = try keyStore.readAPIKey(for: providerID)
            try keyStore.deleteAPIKey(for: providerID)
            if let oldAPIKey {
                return .restore(oldAPIKey)
            }
            return .none
        }
    }

    private func rollbackThenThrow(
        primaryError: Error,
        rollback: CredentialRollback,
        providerID: UUID
    ) throws -> Never {
        do {
            switch rollback {
            case .none:
                break
            case let .restore(apiKey):
                try keyStore.saveAPIKey(apiKey, for: providerID)
            case .delete:
                try keyStore.deleteAPIKey(for: providerID)
            }
        } catch {
            throw AIProviderConfigurationTransactionError(
                primaryError: primaryError,
                rollbackError: error
            )
        }
        throw primaryError
    }

    internal static func withSharedTransaction<T>(_ operation: () throws -> T) rethrows -> T {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return try operation()
    }
}
