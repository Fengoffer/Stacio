import Foundation

public enum ResolvedAIRuntimeTarget: Equatable {
    case external(provider: AIProviderConfiguration, modelID: String)
    case unconfigured(provider: AIProviderConfiguration)
}

public enum AIProviderRuntimeResolver {
    public static func resolve(
        envelope: AIProviderSettingsEnvelope,
        requestedSelection: AIModelSelection?
    ) -> ResolvedAIRuntimeTarget {
        let normalizedEnvelope = AIProviderSettingsNormalizer.normalized(envelope)

        if let requestedSelection,
           requestedSelection.providerID != BuiltInAIProvider.stacioRulesID {
            if let requestedTarget = externalTarget(
                selection: requestedSelection,
                providers: normalizedEnvelope.aiProviders
            ) {
                return requestedTarget
            }
        }

        guard let provider = normalizedEnvelope.aiProviders.first(where: {
            $0.id == normalizedEnvelope.defaultAIProviderID
        }) else {
            return .unconfigured(provider: BuiltInAIProvider.defaultConfiguration)
        }
        if let defaultModelID = provider.defaultModelID,
           let target = externalTarget(
               selection: AIModelSelection(providerID: provider.id, modelID: defaultModelID),
               providers: normalizedEnvelope.aiProviders
           ) {
            return target
        }
        return .unconfigured(provider: provider)
    }

    private static func externalTarget(
        selection: AIModelSelection,
        providers: [AIProviderConfiguration]
    ) -> ResolvedAIRuntimeTarget? {
        let modelID = AppSettings.normalizedAIModelName(selection.modelID)
        guard modelID.isEmpty == false,
              let provider = providers.first(where: { $0.id == selection.providerID }),
              provider.id != BuiltInAIProvider.stacioRulesID,
              provider.isEnabled,
              provider.profile.usesModelInterface,
              provider.models.contains(where: { $0.id == modelID && $0.isEnabled })
        else {
            return nil
        }
        return .external(provider: provider, modelID: modelID)
    }
}
