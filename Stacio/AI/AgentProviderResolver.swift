import Foundation

/// Resolves the active provider and model from the user's saved configuration.
///
/// `AppSettingsStore` remains the single source of truth (the same envelope the
/// settings window edits) and credentials still come from `AIApiKeyStore`. A turn
/// freezes a snapshot so a mid-turn settings change cannot swap the endpoint.
struct AgentProviderResolver {
 struct Resolved {
 var provider: AIProviderConfiguration
 var model: AIProviderModelConfiguration
 var apiKey: String
 var baseURL: String
 }

 enum Failure: Error, CustomStringConvertible {
 case noProviders
 case noEnabledProvider
 case noRunnableModel(String)
 case noCredential(String)
 case invalidBaseURL(String)

 var description: String {
 switch self {
 case .noProviders:
 return "尚未配置模型供应商，请先在「AI设置」中添加。"
 case .noEnabledProvider:
 return "没有已启用的供应商，请在「AI设置」中启用一个并选择默认模型。"
 case .noRunnableModel(let name):
 return "供应商「\(name)」没有可用的默认模型，请先在「AI设置」中选择。"
 case .noCredential(let name):
 return "供应商「\(name)」缺少 API凭据，请在「AI设置」中补充。"
 case .invalidBaseURL(let value):
 return "供应商地址不可用：\(value)"
 }
 }
 }

 private let settingsStore: AppSettingsStore
 private let keyStore: AIApiKeyStoring

 init(settingsStore: AppSettingsStore = AppSettingsStore.shared, keyStore: AIApiKeyStoring = KeychainAIApiKeyStore()) {
 self.settingsStore = settingsStore
 self.keyStore = keyStore
 }

 func modelChoices() -> [AgentModelSelection] {
 let settings = settingsStore.snapshot()
 var choices: [AgentModelSelection] = []
 for provider in settings.aiProviders {
 if provider.isEnabled == false { continue }
 for model in provider.models where model.isEnabled {
 let modelID = model.id
 var selection = AgentModelSelection(providerID: provider.id.uuidString, providerName: provider.displayName, modelID: modelID, modelDisplayName: modelID)
 let cached = DefaultAIModelCatalogLoader.cachedReasoning(provider, modelID)
 selection.supportedEfforts = (model.capabilities.supportedReasoningEfforts ?? cached?.supportedReasoningEfforts)?.map(\.rawValue)
 selection.supportsImages = model.capabilities.supportsImages ?? cached?.supportsImages
 selection.supportsThinking = model.capabilities.supportsThinking ?? cached?.supportsThinking
 selection.reasoningEffort = model.capabilities.reasoningEffort?.rawValue
 choices.append(selection)
 }
 }
 return choices
 }

 func defaultSelection() -> AgentModelSelection? {
 let settings = settingsStore.snapshot()
 for provider in settings.aiProviders where provider.isEnabled {
 if provider.id == settings.defaultAIProviderID {
 if let modelID = provider.defaultModelID {
 return AgentModelSelection(providerID: provider.id.uuidString, providerName: provider.displayName, modelID: modelID, modelDisplayName: modelID)
 }
 }
 }
 for provider in settings.aiProviders where provider.isEnabled {
 if let modelID = provider.defaultModelID {
 return AgentModelSelection(providerID: provider.id.uuidString, providerName: provider.displayName, modelID: modelID, modelDisplayName: modelID)
 }
 }
 return nil
 }

 /// Keep enhancement on the configured provider. Prefer a DeepSeek chat model
 /// there, as OrcaTerm does for this task, and fall back to the selected model.
 func resolveEnhancement(selection: AgentModelSelection?) throws -> Resolved {
 let resolved = try resolve(selection: selection ?? defaultSelection())
 func isDeepSeekChat(_ model: AIProviderModelConfiguration) -> Bool {
 let id = model.id.lowercased()
 return model.isEnabled && id.contains("deepseek")
 && !id.contains("reasoner") && !id.contains("r1") && !id.contains("embed")
 && !id.contains("rerank")
 }
 if isDeepSeekChat(resolved.model) { return resolved }
 guard let preferred = resolved.provider.models.first(where: isDeepSeekChat) else { return resolved }
 var enhancement = resolved
 enhancement.model = preferred
 return enhancement
 }

 func resolve(selection: AgentModelSelection?) throws -> Resolved {
 let settings = settingsStore.snapshot()
 if settings.aiProviders.isEmpty {
 throw Failure.noProviders
 }
 var provider: AIProviderConfiguration?
 if let selection {
 if let id = UUID(uuidString: selection.providerID) {
 provider = settings.aiProviders.first { $0.id == id }
 }
 }
 if provider == nil {
 provider = settings.aiProviders.first { $0.id == settings.defaultAIProviderID }
 }
 guard let resolvedProvider = provider else {
 throw Failure.noEnabledProvider
 }
 return try resolve(provider: resolvedProvider, modelID: selection?.modelID)
 }

 private func resolve(provider: AIProviderConfiguration, modelID requested: String?) throws -> Resolved {
 if provider.isEnabled == false {
 throw Failure.noEnabledProvider
 }
 let enabledModels = provider.models.filter { $0.isEnabled }
 var model: AIProviderModelConfiguration?
 if let requested {
 model = enabledModels.first { $0.id == requested }
 }
 if model == nil, let defaultModelID = provider.defaultModelID {
 model = enabledModels.first { $0.id == defaultModelID }
 }
 if model == nil {
 model = enabledModels.first
 }
 guard let resolvedModel = model else {
 throw Failure.noRunnableModel(provider.displayName)
 }
 guard let normalized = AgentProviderResolver.normalizedBaseURL(provider.baseURL) else {
 throw Failure.invalidBaseURL(provider.baseURL)
 }
 let key = (try? keyStore.readAPIKey(for: provider.id)) ?? nil
 let trimmedKey = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
 if trimmedKey.isEmpty {
 throw Failure.noCredential(provider.displayName)
 }
 return Resolved(provider: provider, model: resolvedModel, apiKey: trimmedKey, baseURL: normalized)
 }

 /// Accepts the shapes users actually paste: host, host/v1, host/v1/, host/v1/chat/completions.
 static func normalizedBaseURL(_ raw: String) -> String? {
 var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
 if value.isEmpty { return nil }
 if value.hasSuffix("/chat/completions") {
 value = String(value.dropLast("/chat/completions".count))
 }
 while value.hasSuffix("/") {
 value.removeLast()
 }
 guard let url = URL(string: value) else { return nil }
 guard let scheme = url.scheme?.lowercased() else { return nil }
 guard scheme == "https" || scheme == "http" else { return nil }
 guard url.host?.isEmpty == false else { return nil }
 return value
 }
}
