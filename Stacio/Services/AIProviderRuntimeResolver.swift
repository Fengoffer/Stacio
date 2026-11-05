import Foundation

public enum ResolvedAIRuntimeTarget: Equatable {
    case external(provider: AIProviderConfiguration, modelID: String)
    case credentialOriginConfirmationRequired(
        provider: AIProviderConfiguration,
        origin: String
    )
    /// `provider == nil` means the user has not selected a provider. A value is
    /// retained only when an explicitly selected configuration is not runnable.
    case unconfigured(provider: AIProviderConfiguration?)
}

public enum AIProviderRuntimeResolver {
    public static func resolve(
        envelope: AIProviderSettingsEnvelope,
        requestedSelection: AIModelSelection?,
        runtimeCatalog: BundledRuntimeCatalog = .shared
    ) -> ResolvedAIRuntimeTarget {
        let normalizedEnvelope = AIProviderSettingsNormalizer.normalized(envelope)

        if let requestedSelection,
           requestedSelection.providerID != BuiltInAIProvider.stacioRulesID {
            if let blockedTarget = credentialOriginBlockedTarget(
                selection: requestedSelection,
                providers: normalizedEnvelope.aiProviders,
                runtimeCatalog: runtimeCatalog
            ) {
                return blockedTarget
            }
            if let requestedTarget = externalTarget(
                selection: requestedSelection,
                providers: normalizedEnvelope.aiProviders,
                runtimeCatalog: runtimeCatalog
            ) {
                return requestedTarget
            }

            // A non-nil selection is an explicit per-Inspector choice. If that
            // exact target is no longer runnable, preserve its provider context
            // and fail closed instead of silently switching to the global
            // default provider or model.
            let requestedProvider = envelope.aiProviders.first {
                $0.id == requestedSelection.providerID
            }
            return .unconfigured(provider: requestedProvider)
        }

        let configuredDefaultProvider = envelope.aiProviders.first {
            $0.id == envelope.defaultAIProviderID
                && $0.id != BuiltInAIProvider.stacioRulesID
        }
        guard let provider = normalizedEnvelope.aiProviders.first(where: {
            $0.id == normalizedEnvelope.defaultAIProviderID
        }) else {
            return .unconfigured(provider: configuredDefaultProvider)
        }
        if let defaultModelID = provider.defaultModelID,
           let blockedTarget = credentialOriginBlockedTarget(
               selection: AIModelSelection(providerID: provider.id, modelID: defaultModelID),
               providers: normalizedEnvelope.aiProviders,
               runtimeCatalog: runtimeCatalog
           ) {
            return blockedTarget
        }
        if let defaultModelID = provider.defaultModelID,
           let target = externalTarget(
               selection: AIModelSelection(providerID: provider.id, modelID: defaultModelID),
               providers: normalizedEnvelope.aiProviders,
               runtimeCatalog: runtimeCatalog
           ) {
            return target
        }
        return .unconfigured(provider: configuredDefaultProvider ?? provider)
    }

    private static func credentialOriginBlockedTarget(
        selection: AIModelSelection,
        providers: [AIProviderConfiguration],
        runtimeCatalog: BundledRuntimeCatalog
    ) -> ResolvedAIRuntimeTarget? {
        let modelID = AppSettings.normalizedAIModelName(selection.modelID)
        guard modelID.isEmpty == false,
              let provider = providers.first(where: { $0.id == selection.providerID }),
              provider.id != BuiltInAIProvider.stacioRulesID,
              provider.isEnabled,
              provider.profile.usesModelInterface,
              AIProviderRuntimeEligibility.isConfigurationStructurallyRunnable(
                  provider,
                  runtimeCatalog: runtimeCatalog
              ),
              AIProviderRuntimeEligibility.runnableModel(id: modelID, in: provider) != nil,
              case let .confirmationRequired(origin) = AIProviderCredentialOriginPolicy.authorization(
                  for: provider,
                  runtimeCatalog: runtimeCatalog
              )
        else {
            return nil
        }
        return .credentialOriginConfirmationRequired(provider: provider, origin: origin)
    }

    private static func externalTarget(
        selection: AIModelSelection,
        providers: [AIProviderConfiguration],
        runtimeCatalog: BundledRuntimeCatalog
    ) -> ResolvedAIRuntimeTarget? {
        let modelID = AppSettings.normalizedAIModelName(selection.modelID)
        guard modelID.isEmpty == false,
              let provider = providers.first(where: { $0.id == selection.providerID }),
              provider.id != BuiltInAIProvider.stacioRulesID,
              provider.isEnabled,
              provider.profile.usesModelInterface,
              AIProviderRuntimeEligibility.isConfigurationRunnable(
                  provider,
                  runtimeCatalog: runtimeCatalog
              ),
              AIProviderRuntimeEligibility.runnableModel(id: modelID, in: provider) != nil
        else {
            return nil
        }
        return .external(provider: provider, modelID: modelID)
    }
}
