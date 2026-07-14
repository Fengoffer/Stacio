import Foundation

public enum ResolvedAIRuntimeTarget: Equatable {
    case stacioRules
    case external(provider: AIProviderConfiguration, modelID: String)
}

public enum AIProviderRuntimeResolver {
    public static func resolve(
        envelope: AIProviderSettingsEnvelope,
        requestedSelection: AIModelSelection?
    ) -> ResolvedAIRuntimeTarget {
        let normalizedEnvelope = AIProviderSettingsNormalizer.normalized(envelope)

        if let requestedSelection {
            if requestedSelection.providerID == BuiltInAIProvider.stacioRulesID {
                return .stacioRules
            }
            if let requestedTarget = externalTarget(
                selection: requestedSelection,
                providers: normalizedEnvelope.aiProviders
            ) {
                return requestedTarget
            }
        }

        guard normalizedEnvelope.defaultAIProviderID != BuiltInAIProvider.stacioRulesID else {
            return .stacioRules
        }

        if let provider = normalizedEnvelope.aiProviders.first(where: {
            $0.id == normalizedEnvelope.defaultAIProviderID
        }),
           let defaultModelID = provider.defaultModelID,
           let target = externalTarget(
               selection: AIModelSelection(providerID: provider.id, modelID: defaultModelID),
               providers: normalizedEnvelope.aiProviders
           ) {
            return target
        }

        for provider in normalizedEnvelope.aiProviders
        where provider.id != normalizedEnvelope.defaultAIProviderID {
            guard let defaultModelID = provider.defaultModelID,
                  let target = externalTarget(
                      selection: AIModelSelection(providerID: provider.id, modelID: defaultModelID),
                      providers: normalizedEnvelope.aiProviders
                  )
            else {
                continue
            }
            return target
        }
        return .stacioRules
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
