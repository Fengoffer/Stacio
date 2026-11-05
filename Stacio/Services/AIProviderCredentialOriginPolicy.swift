import Foundation

public enum AIProviderCredentialOriginAuthorization: Equatable {
    /// The catalog says this configuration sends no credential, or its current
    /// origin is the catalog-suggested API origin.
    case confirmationNotRequired
    /// The current custom origin matches the local persisted approval.
    case confirmed(origin: String)
    /// A credential-bearing request must not start until this origin is approved.
    case confirmationRequired(origin: String)
    case invalidBaseURL
}

public struct AIProviderCredentialOriginConfirmationRequest: Equatable {
    public let providerName: String
    public let origin: String
    public let credentialPurpose: String

    public init(providerName: String, origin: String, credentialPurpose: String) {
        self.providerName = providerName
        self.origin = origin
        self.credentialPurpose = credentialPurpose
    }
}

public typealias AIProviderCredentialOriginConfirmationHandler = @MainActor (
    AIProviderCredentialOriginConfirmationRequest
) -> Bool

/// One fail-closed policy shared by settings UI and live runtime routing.
public enum AIProviderCredentialOriginPolicy {
    public static func requiresCredential(
        for provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> Bool {
        catalogDescriptor(for: provider, runtimeCatalog: runtimeCatalog)?.requiresCredential ?? true
    }

    /// A stale Keychain item must never turn a catalog-declared no-auth
    /// configuration into a credential-bearing request.
    public static func credentialForRequest(
        _ apiKey: String?,
        provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> String? {
        guard requiresCredential(for: provider, runtimeCatalog: runtimeCatalog) else {
            return nil
        }
        let normalized = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    public static func authorization(
        for provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> AIProviderCredentialOriginAuthorization {
        let descriptor = catalogDescriptor(for: provider, runtimeCatalog: runtimeCatalog)
        if requiresCredential(for: provider, runtimeCatalog: runtimeCatalog) == false {
            return .confirmationNotRequired
        }

        guard let currentOrigin = normalizedOrigin(forBaseURL: provider.baseURL) else {
            return .invalidBaseURL
        }

        if let suggestedBaseURL = descriptor?.suggestedBaseURL,
           normalizedOrigin(forBaseURL: suggestedBaseURL) == currentOrigin {
            return .confirmationNotRequired
        }

        if provider.confirmedCredentialOrigin == currentOrigin {
            return .confirmed(origin: currentOrigin)
        }
        return .confirmationRequired(origin: currentOrigin)
    }

    public static func isCredentialUseAuthorized(
        for provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> Bool {
        switch authorization(for: provider, runtimeCatalog: runtimeCatalog) {
        case .confirmationNotRequired, .confirmed:
            return true
        case .confirmationRequired, .invalidBaseURL:
            return false
        }
    }

    public static func pendingConfirmationOrigin(
        for provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> String? {
        guard case let .confirmationRequired(origin) = authorization(
            for: provider,
            runtimeCatalog: runtimeCatalog
        ) else {
            return nil
        }
        return origin
    }

    public static func normalizedOrigin(forBaseURL rawBaseURL: String) -> String? {
        guard let url = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: rawBaseURL) else {
            return nil
        }
        return WebsiteActionResolver.normalizedOrigin(url: url)
    }

    private static func catalogDescriptor(
        for provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog
    ) -> NativeRuntimeCatalogEntry? {
        if let descriptor = runtimeCatalog.nativeRuntimeEntry(catalogID: provider.catalogID) {
            return descriptor
        }
        guard provider.catalogID == nil,
              let legacy = runtimeCatalog.provider(
                  legacyProfileRawValue: provider.profile.rawValue,
                  baseURL: provider.baseURL
              )
        else {
            return nil
        }

        // A profile match alone must never turn an arbitrary OpenAI-compatible
        // endpoint into a hosted provider's trusted API origin.
        guard normalizedOrigin(forBaseURL: legacy.suggestedBaseURL ?? "")
            == normalizedOrigin(forBaseURL: provider.baseURL) else {
            return nil
        }
        return .provider(legacy)
    }
}
