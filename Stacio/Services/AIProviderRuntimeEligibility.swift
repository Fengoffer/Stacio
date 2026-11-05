import Foundation

/// Single fail-closed contract for models that may be used by a live runtime.
public enum AIProviderRuntimeEligibility {
    public static func isConfigurationRunnable(
        _ provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> Bool {
        switch AIProviderCredentialOriginPolicy.authorization(
            for: provider,
            runtimeCatalog: runtimeCatalog
        ) {
        case .confirmationNotRequired, .confirmed:
            break
        case .confirmationRequired, .invalidBaseURL:
            return false
        }
        return isConfigurationStructurallyRunnable(
            provider,
            runtimeCatalog: runtimeCatalog
        )
    }

    public static func isConfigurationStructurallyRunnable(
        _ provider: AIProviderConfiguration,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> Bool {
        guard let baseURL = OpenAICompatibleAIAssistantProvider.normalizedBaseURL(
            from: provider.baseURL
        ) else {
            return false
        }
        do {
            try AIEndpointSecurityPolicy.validate(baseURL)
        } catch {
            return false
        }
        guard let catalogID = provider.catalogID else {
            // Catalog-less V1 records remain available only as the explicit
            // migration path for ordinary providers.
            return provider.effectiveRuntimeConfigurationKind == .provider
        }
        guard provider.lastVerifiedAt != nil,
              let entry = runtimeCatalog.nativeRuntimeEntry(catalogID: catalogID)
        else {
            return false
        }
        return entry.isCodingPlan
            ? provider.effectiveRuntimeConfigurationKind == .codingPlan
            : provider.effectiveRuntimeConfigurationKind == .provider
    }

    public static func isModelRunnable(
        _ model: AIProviderModelConfiguration,
        in provider: AIProviderConfiguration
    ) -> Bool {
        guard model.isEnabled else { return false }

        // V1 records predate catalog identity and per-model verification. Preserve
        // their existing enabled-model behavior until the user migrates them.
        guard provider.catalogID != nil else { return true }

        if model.isManual {
            return model.lastVerifiedAt != nil
        }

        return model.wasReturnedByLatestCatalog
    }

    public static func runnableModel(
        id rawModelID: String,
        in provider: AIProviderConfiguration
    ) -> AIProviderModelConfiguration? {
        let modelID = AppSettings.normalizedAIModelName(rawModelID)
        guard modelID.isEmpty == false,
              let model = provider.models.first(where: { $0.id == modelID }),
              isModelRunnable(model, in: provider)
        else {
            return nil
        }
        return model
    }
}
