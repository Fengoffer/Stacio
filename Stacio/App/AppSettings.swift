import AppKit
import Foundation
import StacioCoreBindings
import SwiftTerm

public enum TerminalThemePreference: String, Equatable {
    case system
    case light
    case dark
    case custom
}

public enum SessionTabIconModePreference: String, Equatable {
    case defaultIcon
    case operatingSystem
}

public enum TerminalRightClickBehaviorPreference: String, Equatable {
    case paste
    case contextMenu
    case none
}

public enum TerminalHighlightLevelPreference: String, Equatable {
    case off
    case ansiOnly
    case commandLineEnhanced
}

public enum TerminalFontFamilyPreference: String, CaseIterable, Equatable {
    case sfMono
    case menlo
    case monaco
    case jetBrainsMono
    case firaCode
    case hack
    case sourceCodePro
    case cascadiaCode
    case consolas

    public var displayName: String {
        switch self {
        case .sfMono:
            return "SF Mono"
        case .menlo:
            return "Menlo"
        case .monaco:
            return "Monaco"
        case .jetBrainsMono:
            return "JetBrains Mono"
        case .firaCode:
            return "Fira Code"
        case .hack:
            return "Hack"
        case .sourceCodePro:
            return "Source Code Pro"
        case .cascadiaCode:
            return "Cascadia Code"
        case .consolas:
            return "Consolas"
        }
    }

    public var fontNames: [String] {
        switch self {
        case .sfMono:
            return ["SFMono-Regular", "SF Mono"]
        case .menlo:
            return ["Menlo-Regular", "Menlo"]
        case .monaco:
            return ["Monaco"]
        case .jetBrainsMono:
            return ["JetBrainsMono-Regular", "JetBrains Mono"]
        case .firaCode:
            return ["FiraCode-Regular", "Fira Code"]
        case .hack:
            return ["Hack-Regular", "Hack"]
        case .sourceCodePro:
            return ["SourceCodePro-Regular", "Source Code Pro"]
        case .cascadiaCode:
            return ["CascadiaCode-Regular", "Cascadia Code"]
        case .consolas:
            return ["Consolas"]
        }
    }
}

public enum TerminalCursorShapePreference: String, Equatable {
    case block
    case bar
    case underline
}

public enum AgentConfirmationPolicyPreference: String, Equatable {
    case allowAllWithoutPrompt
    case allowLowRiskWithoutPrompt
    case requireEveryCommand
    case allowReadOnlyWithoutPrompt

    public var authorizationPolicy: AgentAuthorizationPolicy {
        switch self {
        case .allowAllWithoutPrompt:
            return .allowAllCommandsWithoutPrompt
        case .allowLowRiskWithoutPrompt:
            return .allowLowRiskCommandsWithoutPrompt
        case .requireEveryCommand:
            return .requireConfirmationForAll
        case .allowReadOnlyWithoutPrompt:
            return .allowReadOnlyExternalCommands
        }
    }

    public static func fromStoredRawValue(_ rawValue: String?) -> AgentConfirmationPolicyPreference {
        guard let rawValue,
              let policy = AgentConfirmationPolicyPreference(rawValue: rawValue)
        else {
            return .allowLowRiskWithoutPrompt
        }
        return policy
    }
}

public enum AgentExecutionModePreference: String, Equatable {
    case visibleTerminal
    case backgroundTask
}

public enum AIReasoningEffortPreference: String, CaseIterable, Codable, Equatable {
    case minimal
    case low
    case medium
    case high
}

public enum AICompatibilityProtocolPreference: String, Codable, Equatable {
    case chatCompletions
    case responses
}

public enum AIProviderProfile: String, CaseIterable, Codable, Equatable {
    case portDeskRules = "Stacio Rules"
    case openAI = "OpenAI"
    case deepSeek = "DeepSeek"
    case openRouter = "OpenRouter"
    case qwen = "Qwen"
    case kimi = "Kimi"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case openAICompatible = "OpenAI Compatible"

    public static let settingsMenuProfiles: [AIProviderProfile] = [
        .portDeskRules,
        .openAI,
        .deepSeek,
        .openRouter,
        .qwen,
        .kimi,
        .ollama,
        .lmStudio,
        .openAICompatible
    ]

    public var displayName: String {
        switch self {
        case .portDeskRules:
            return L10n.Settings.portDeskRules
        case .openAI:
            return L10n.Settings.aiPresetOpenAI
        case .deepSeek:
            return L10n.Settings.aiPresetDeepSeek
        case .openRouter:
            return L10n.Settings.aiPresetOpenRouter
        case .qwen:
            return L10n.Settings.aiPresetQwen
        case .kimi:
            return L10n.Settings.aiPresetKimi
        case .ollama:
            return L10n.Settings.aiPresetOllama
        case .lmStudio:
            return L10n.Settings.aiPresetLMStudio
        case .openAICompatible:
            return L10n.Settings.openAICompatible
        }
    }

    public var usesModelInterface: Bool {
        self != .portDeskRules
    }

    public var defaultBaseURL: String? {
        switch self {
        case .portDeskRules, .openAICompatible:
            return nil
        case .openAI:
            return "https://api.openai.com/v1"
        case .deepSeek:
            return "https://api.deepseek.com/v1"
        case .openRouter:
            return "https://openrouter.ai/api/v1"
        case .qwen:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi:
            return "https://api.moonshot.cn/v1"
        case .ollama:
            return "localhost:11434/v1"
        case .lmStudio:
            return "localhost:1234/v1"
        }
    }

    public var defaultModel: String? {
        switch self {
        case .portDeskRules, .openAICompatible:
            return nil
        case .openAI:
            return "gpt-4.1-mini"
        case .deepSeek:
            return "deepseek-chat"
        case .openRouter:
            return "openai/gpt-4.1-mini"
        case .qwen:
            return "qwen-plus"
        case .kimi:
            return "kimi-k2-0905-preview"
        case .ollama:
            return "qwen2.5-coder"
        case .lmStudio:
            return "local-model"
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .portDeskRules, .openAICompatible:
            return []
        case .openAI:
            return ["gpt-4.1-mini", "gpt-4.1", "gpt-4o-mini"]
        case .deepSeek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .openRouter:
            return ["openai/gpt-4.1-mini"]
        case .qwen:
            return ["qwen-plus", "qwen-max", "qwen-turbo"]
        case .kimi:
            return ["kimi-k2-0905-preview"]
        case .ollama:
            return ["qwen2.5-coder", "llama3.1", "qwen2.5"]
        case .lmStudio:
            return ["local-model"]
        }
    }

    public static func profile(for value: String) -> AIProviderProfile {
        recognizedProfile(for: value) ?? .portDeskRules
    }

    public static func recognizedProfile(for value: String) -> AIProviderProfile? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.first { profile in
            profile.rawValue.caseInsensitiveCompare(cleaned) == .orderedSame
                || profile.displayName.caseInsensitiveCompare(cleaned) == .orderedSame
        }
    }

    public static func isModelInterfaceProvider(_ value: String) -> Bool {
        profile(for: value).usesModelInterface
    }
}

public enum FilesTransferConflictPolicyPreference: String, CaseIterable, Equatable {
    case ask
    case keepBoth
    case overwrite
    case rename
    case skip

    public var displayName: String {
        switch self {
        case .ask:
            return "每次询问"
        case .keepBoth:
            return "保留两份"
        case .overwrite:
            return "覆盖"
        case .rename:
            return "重命名"
        case .skip:
            return "跳过"
        }
    }

    public var scpConflictPolicy: ScpConflictPolicy? {
        switch self {
        case .ask:
            return nil
        case .keepBoth:
            return .keepBoth
        case .overwrite:
            return .overwrite
        case .rename:
            return .rename
        case .skip:
            return .skip
        }
    }
}

private let compatibilityAIProviderID = UUID(
    uuidString: "00000000-0000-0000-0000-000000000002"
)!

private func legacyAIProviderConfiguration(
    id: UUID,
    profile: AIProviderProfile,
    baseURL: String,
    model: String,
    customModels: [String],
    compatibilityProtocol: AICompatibilityProtocolPreference,
    maxRetryCount: Int,
    requestTimeoutSeconds: Int,
    userAgent: String,
    legacyReasoningEffort: AIReasoningEffortPreference? = nil,
    legacyContextCharacterLimit: Int? = nil
) -> AIProviderConfiguration {
    var seenModelIDs = Set<String>()
    var models: [AIProviderModelConfiguration] = []

    func appendModels(_ modelIDs: [String], isManual: Bool) {
        for modelID in AppSettings.normalizedAIModelList(modelIDs)
            where seenModelIDs.insert(modelID).inserted {
            models.append(
                .init(
                    id: modelID,
                    isEnabled: true,
                    isManual: isManual,
                    wasReturnedByLatestCatalog: false,
                    capabilities: legacyCapabilities(
                        reasoningEffort: legacyReasoningEffort,
                        contextCharacterLimit: legacyContextCharacterLimit
                    )
                )
            )
        }
    }

    appendModels(profile.suggestedModels, isManual: false)
    appendModels(customModels, isManual: true)
    let currentModelID = AppSettings.normalizedAIModelName(model)
    appendModels([currentModelID], isManual: true)

    let profileDefaultModelID = profile.defaultModel.map(AppSettings.normalizedAIModelName)
    let defaultModelID = currentModelID.isEmpty == false
        ? currentModelID
        : profileDefaultModelID.flatMap { $0.isEmpty ? nil : $0 } ?? models.first?.id
    if let defaultModelID,
       seenModelIDs.insert(defaultModelID).inserted {
        models.append(
            .init(
                id: defaultModelID,
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: false,
                capabilities: legacyCapabilities(
                    reasoningEffort: legacyReasoningEffort,
                    contextCharacterLimit: legacyContextCharacterLimit
                )
            )
        )
    }

    return AIProviderConfiguration(
        id: id,
        profile: profile,
        displayName: profile.displayName,
        baseURL: baseURL,
        models: models,
        defaultModelID: defaultModelID,
        compatibilityProtocol: compatibilityProtocol,
        maxRetryCount: AppSettings.clampedAIRetryCount(maxRetryCount),
        requestTimeoutSeconds: AppSettings.clampedAITimeoutSeconds(requestTimeoutSeconds),
        userAgent: AppSettings.normalizedAIUserAgent(userAgent),
        isEnabled: true,
        lastVerifiedAt: nil,
        lastModelSyncAt: nil
    )
}

private func legacyCapabilities(
    reasoningEffort: AIReasoningEffortPreference?,
    contextCharacterLimit: Int?
) -> AIModelCapabilityConfiguration {
    AIModelCapabilityConfiguration(
        contextCharacterLimit: contextCharacterLimit,
        contextCharacterLimitSource: .unknown,
        reasoningEffort: reasoningEffort,
        reasoningEffortSource: .unknown
    )
}

public struct AppSettings: Equatable {
    public var terminalFontSize: Double
    public var terminalFontFamily: TerminalFontFamilyPreference
    public var terminalTheme: TerminalThemePreference
    public var sessionTabIconMode: SessionTabIconModePreference
    public var terminalBuiltInThemeID: String
    public var terminalCloseConfirmationEnabled: Bool
    public var terminalSelectionAutoCopyEnabled: Bool
    public var terminalRightClickBehavior: TerminalRightClickBehaviorPreference
    public var terminalHighlightLevel: TerminalHighlightLevelPreference
    public var terminalRichHighlightingEnabled: Bool
    public var terminalControlScrollZoomEnabled: Bool
    public var terminalScrollbackLines: Int
    public var terminalKeepAliveIntervalSeconds: Int
    public var terminalX11Display: String
    public var terminalHardwareAccelerationEnabled: Bool
    public var terminalWorkspacePaddingEnabled: Bool
    public var terminalLineNumbersEnabled: Bool
    public var terminalTimestampsEnabled: Bool
    public var terminalTimestampMillisecondsEnabled: Bool
    public var terminalMultiLinePasteConfirmationEnabled: Bool
    public var terminalPasteImageAsPathEnabled: Bool
    public var terminalAltAsMetaEnabled: Bool
    public var terminalMacIMECompatibilityEnabled: Bool
    public var terminalCommandSuggestionEnabled: Bool
    public var terminalCommandSuggestionHistoryMinLength: Int
    public var terminalCommandSuggestionHistoryMaxLength: Int
    public var terminalCommandSuggestionWordSeparators: String
    public var terminalDuplicateSessionCommandDelayMilliseconds: Int
    public var terminalCommandCompletionNotificationEnabled: Bool
    public var terminalCommandCompletionNotificationThresholdSeconds: Int
    public var terminalCursorShape: TerminalCursorShapePreference
    public var terminalCursorBlinkEnabled: Bool
    public var customTerminalTheme: TerminalColorTheme?
    public var aiProviderSettings: AIProviderSettingsEnvelope
    public var aiProviders: [AIProviderConfiguration] {
        aiProviderSettings.aiProviders
    }
    public var defaultAIProviderID: UUID {
        aiProviderSettings.defaultAIProviderID
    }
    public var aiProvider: String {
        get {
            selectedAIProvider?.profile.rawValue ?? AIProviderProfile.portDeskRules.rawValue
        }
        set {
            guard let profile = AIProviderProfile.recognizedProfile(for: newValue),
                  profile.usesModelInterface
            else {
                aiProviderSettings.defaultAIProviderID = BuiltInAIProvider.stacioRulesID
                return
            }

            if let index = selectedAIProviderIndex
                ?? aiProviderSettings.aiProviders.firstIndex(where: { $0.id == compatibilityAIProviderID }) {
                aiProviderSettings.aiProviders[index].profile = profile
                aiProviderSettings.aiProviders[index].displayName = profile.displayName
                aiProviderSettings.defaultAIProviderID = aiProviderSettings.aiProviders[index].id
            } else {
                let provider = legacyAIProviderConfiguration(
                    id: compatibilityAIProviderID,
                    profile: profile,
                    baseURL: profile.defaultBaseURL ?? "",
                    model: profile.defaultModel ?? "",
                    customModels: [],
                    compatibilityProtocol: .chatCompletions,
                    maxRetryCount: 1,
                    requestTimeoutSeconds: 45,
                    userAgent: "Stacio"
                )
                aiProviderSettings.aiProviders.append(provider)
                aiProviderSettings.defaultAIProviderID = provider.id
            }
        }
    }
    public var aiBaseURL: String {
        get { selectedAIProvider?.baseURL ?? "" }
        set {
            guard let index = selectedAIProviderIndex else { return }
            aiProviderSettings.aiProviders[index].baseURL = newValue
        }
    }
    public var aiModel: String {
        get { selectedAIProvider?.defaultModelID ?? "" }
        set {
            guard let index = selectedAIProviderIndex else { return }
            let modelID = Self.normalizedAIModelName(newValue)
            guard modelID.isEmpty == false else {
                aiProviderSettings.aiProviders[index].defaultModelID = nil
                return
            }
            if let modelIndex = aiProviderSettings.aiProviders[index].models.firstIndex(where: { $0.id == modelID }) {
                aiProviderSettings.aiProviders[index].models[modelIndex].isEnabled = true
            } else {
                aiProviderSettings.aiProviders[index].models.append(
                    .init(
                        id: modelID,
                        isEnabled: true,
                        isManual: true,
                        wasReturnedByLatestCatalog: false
                    )
                )
            }
            aiProviderSettings.aiProviders[index].defaultModelID = modelID
            aiProviderSettings.aiProviders[index].isEnabled = true
        }
    }
    public var aiMaxRetryCount: Int {
        get { selectedAIProvider?.maxRetryCount ?? 1 }
        set {
            guard let index = selectedAIProviderIndex else { return }
            aiProviderSettings.aiProviders[index].maxRetryCount = Self.clampedAIRetryCount(newValue)
        }
    }
    public var aiUserAgent: String {
        get { selectedAIProvider?.userAgent ?? "Stacio" }
        set {
            guard let index = selectedAIProviderIndex else { return }
            aiProviderSettings.aiProviders[index].userAgent = Self.normalizedAIUserAgent(newValue)
        }
    }
    public var aiRequestTimeoutSeconds: Int {
        get { selectedAIProvider?.requestTimeoutSeconds ?? 45 }
        set {
            guard let index = selectedAIProviderIndex else { return }
            aiProviderSettings.aiProviders[index].requestTimeoutSeconds = Self.clampedAITimeoutSeconds(newValue)
        }
    }
    public var aiCustomModels: [String] {
        get {
            selectedAIProvider?.models.filter(\.isManual).map(\.id) ?? []
        }
        set {
            guard let index = selectedAIProviderIndex else { return }
            let provider = aiProviderSettings.aiProviders[index]
            let replacement = legacyAIProviderConfiguration(
                id: provider.id,
                profile: provider.profile,
                baseURL: provider.baseURL,
                model: provider.defaultModelID ?? "",
                customModels: newValue,
                compatibilityProtocol: provider.compatibilityProtocol,
                maxRetryCount: provider.maxRetryCount,
                requestTimeoutSeconds: provider.requestTimeoutSeconds,
                userAgent: provider.userAgent
            )
            aiProviderSettings.aiProviders[index].models = replacement.models
            aiProviderSettings.aiProviders[index].defaultModelID = replacement.defaultModelID
        }
    }
    public var aiReasoningEffort: AIReasoningEffortPreference
    public var aiCompatibilityProtocol: AICompatibilityProtocolPreference {
        get { selectedAIProvider?.compatibilityProtocol ?? .chatCompletions }
        set {
            guard let index = selectedAIProviderIndex else { return }
            aiProviderSettings.aiProviders[index].compatibilityProtocol = newValue
        }
    }
    public var aiIncludeRecentTerminalTranscript: Bool
    public var aiContextCharacterLimit: Int
    public var agentConfirmationPolicy: AgentConfirmationPolicyPreference
    public var agentExecutionMode: AgentExecutionModePreference
    public var aiAutoRunProposedCommands: Bool
    public var agentCommandAllowPatterns: String
    public var agentCommandDenyPatterns: String
    public var filesDirectoryFollowDefault: Bool
    public var filesShowHiddenFilesByDefault: Bool
    public var filesRemoteEditAutoDetectChanges: Bool
    public var filesTransferConflictPolicy: FilesTransferConflictPolicyPreference
    public var filesTransferQueueVisibleByDefault: Bool
    public var deviceMetricsRefreshIntervalSeconds: Int
    public var deviceMetricsKeepLastSnapshotOnFailure: Bool
    public var deviceMetricsShowNetworkSection: Bool
    public var deviceMetricsShowDiskSection: Bool
    public var deviceMetricsDiskMountLimit: Int
    public var deviceMetricsHideVirtualNetworkInterfaces: Bool
    public var deviceMetricsHistorySampleCount: Int
    public var deviceMetricsAlertEnabled: Bool
    public var deviceMetricsCPUAlertThresholdPercent: Int
    public var deviceMetricsMemoryAlertThresholdPercent: Int
    public var deviceMetricsDiskAlertThresholdPercent: Int
    public var deviceMetricsAlertConsecutiveRefreshCount: Int
    public var diagnosticsAuditExportLimit: Int
    public var diagnosticsAppLogLineLimit: Int
    public var diagnosticsIncludeAppLogs: Bool

    public init(
        terminalFontSize: Double = 13,
        terminalFontFamily: TerminalFontFamilyPreference = .sfMono,
        terminalTheme: TerminalThemePreference = .system,
        sessionTabIconMode: SessionTabIconModePreference = .defaultIcon,
        terminalBuiltInThemeID: String = "stacio-dark",
        terminalCloseConfirmationEnabled: Bool = true,
        terminalSelectionAutoCopyEnabled: Bool = true,
        terminalRightClickBehavior: TerminalRightClickBehaviorPreference = .paste,
        terminalHighlightLevel: TerminalHighlightLevelPreference = .commandLineEnhanced,
        terminalRichHighlightingEnabled: Bool = true,
        terminalControlScrollZoomEnabled: Bool = true,
        terminalScrollbackLines: Int = 10_000,
        terminalKeepAliveIntervalSeconds: Int = 60,
        terminalX11Display: String = "",
        terminalHardwareAccelerationEnabled: Bool = false,
        terminalWorkspacePaddingEnabled: Bool = false,
        terminalLineNumbersEnabled: Bool = false,
        terminalTimestampsEnabled: Bool = false,
        terminalTimestampMillisecondsEnabled: Bool = false,
        terminalMultiLinePasteConfirmationEnabled: Bool = true,
        terminalPasteImageAsPathEnabled: Bool = true,
        terminalAltAsMetaEnabled: Bool = false,
        terminalMacIMECompatibilityEnabled: Bool = false,
        terminalCommandSuggestionEnabled: Bool = true,
        terminalCommandSuggestionHistoryMinLength: Int = 2,
        terminalCommandSuggestionHistoryMaxLength: Int = 64,
        terminalCommandSuggestionWordSeparators: String = AppSettings.defaultTerminalCommandSuggestionWordSeparators,
        terminalDuplicateSessionCommandDelayMilliseconds: Int = 1_000,
        terminalCommandCompletionNotificationEnabled: Bool = true,
        terminalCommandCompletionNotificationThresholdSeconds: Int = 5,
        terminalCursorShape: TerminalCursorShapePreference = .block,
        terminalCursorBlinkEnabled: Bool = true,
        customTerminalTheme: TerminalColorTheme? = nil,
        aiProviderSettings: AIProviderSettingsEnvelope? = nil,
        aiProvider: String = AIProviderProfile.portDeskRules.rawValue,
        aiBaseURL: String = "",
        aiModel: String = "",
        aiMaxRetryCount: Int = 1,
        aiUserAgent: String = "Stacio",
        aiRequestTimeoutSeconds: Int = 45,
        aiCustomModels: [String] = [],
        aiReasoningEffort: AIReasoningEffortPreference = .medium,
        aiCompatibilityProtocol: AICompatibilityProtocolPreference = .chatCompletions,
        aiIncludeRecentTerminalTranscript: Bool = true,
        aiContextCharacterLimit: Int = 12_000,
        agentConfirmationPolicy: AgentConfirmationPolicyPreference = .allowLowRiskWithoutPrompt,
        agentExecutionMode: AgentExecutionModePreference = .backgroundTask,
        aiAutoRunProposedCommands: Bool = true,
        agentCommandAllowPatterns: String = "",
        agentCommandDenyPatterns: String = "",
        filesDirectoryFollowDefault: Bool = true,
        filesShowHiddenFilesByDefault: Bool = true,
        filesRemoteEditAutoDetectChanges: Bool = true,
        filesTransferConflictPolicy: FilesTransferConflictPolicyPreference = .ask,
        filesTransferQueueVisibleByDefault: Bool = true,
        deviceMetricsRefreshIntervalSeconds: Int = 2,
        deviceMetricsKeepLastSnapshotOnFailure: Bool = true,
        deviceMetricsShowNetworkSection: Bool = true,
        deviceMetricsShowDiskSection: Bool = true,
        deviceMetricsDiskMountLimit: Int = 5,
        deviceMetricsHideVirtualNetworkInterfaces: Bool = true,
        deviceMetricsHistorySampleCount: Int = 42,
        deviceMetricsAlertEnabled: Bool = true,
        deviceMetricsCPUAlertThresholdPercent: Int = 90,
        deviceMetricsMemoryAlertThresholdPercent: Int = 90,
        deviceMetricsDiskAlertThresholdPercent: Int = 90,
        deviceMetricsAlertConsecutiveRefreshCount: Int = 2,
        diagnosticsAuditExportLimit: Int = 20,
        diagnosticsAppLogLineLimit: Int = 200,
        diagnosticsIncludeAppLogs: Bool = true
    ) {
        self.terminalFontSize = terminalFontSize
        self.terminalFontFamily = terminalFontFamily
        self.terminalTheme = terminalTheme
        self.sessionTabIconMode = sessionTabIconMode
        self.terminalBuiltInThemeID = TerminalColorTheme.resolvedBuiltInTheme(id: terminalBuiltInThemeID).id ?? "stacio-dark"
        self.terminalCloseConfirmationEnabled = terminalCloseConfirmationEnabled
        self.terminalSelectionAutoCopyEnabled = terminalSelectionAutoCopyEnabled
        self.terminalRightClickBehavior = terminalRightClickBehavior
        self.terminalHighlightLevel = terminalHighlightLevel
        self.terminalRichHighlightingEnabled = terminalRichHighlightingEnabled
        self.terminalControlScrollZoomEnabled = terminalControlScrollZoomEnabled
        self.terminalScrollbackLines = Self.clampedTerminalScrollbackLines(terminalScrollbackLines)
        self.terminalKeepAliveIntervalSeconds = Self.clampedTerminalKeepAliveIntervalSeconds(terminalKeepAliveIntervalSeconds)
        self.terminalX11Display = Self.normalizedTerminalX11Display(terminalX11Display)
        self.terminalHardwareAccelerationEnabled = terminalHardwareAccelerationEnabled
        self.terminalWorkspacePaddingEnabled = terminalWorkspacePaddingEnabled
        self.terminalLineNumbersEnabled = terminalLineNumbersEnabled
        self.terminalTimestampsEnabled = terminalTimestampsEnabled
        self.terminalTimestampMillisecondsEnabled = terminalTimestampMillisecondsEnabled
        self.terminalMultiLinePasteConfirmationEnabled = terminalMultiLinePasteConfirmationEnabled
        self.terminalPasteImageAsPathEnabled = terminalPasteImageAsPathEnabled
        self.terminalAltAsMetaEnabled = terminalAltAsMetaEnabled
        self.terminalMacIMECompatibilityEnabled = terminalMacIMECompatibilityEnabled
        self.terminalCommandSuggestionEnabled = terminalCommandSuggestionEnabled
        self.terminalCommandSuggestionHistoryMinLength = Self.clampedTerminalCommandSuggestionHistoryMinLength(terminalCommandSuggestionHistoryMinLength)
        self.terminalCommandSuggestionHistoryMaxLength = Self.clampedTerminalCommandSuggestionHistoryMaxLength(terminalCommandSuggestionHistoryMaxLength)
        if self.terminalCommandSuggestionHistoryMaxLength < self.terminalCommandSuggestionHistoryMinLength {
            self.terminalCommandSuggestionHistoryMaxLength = self.terminalCommandSuggestionHistoryMinLength
        }
        self.terminalCommandSuggestionWordSeparators = Self.normalizedTerminalCommandSuggestionWordSeparators(terminalCommandSuggestionWordSeparators)
        self.terminalDuplicateSessionCommandDelayMilliseconds = Self.clampedTerminalDuplicateSessionCommandDelayMilliseconds(terminalDuplicateSessionCommandDelayMilliseconds)
        self.terminalCommandCompletionNotificationEnabled = terminalCommandCompletionNotificationEnabled
        self.terminalCommandCompletionNotificationThresholdSeconds = Self.clampedTerminalCommandCompletionNotificationThresholdSeconds(
            terminalCommandCompletionNotificationThresholdSeconds
        )
        self.terminalCursorShape = terminalCursorShape
        self.terminalCursorBlinkEnabled = terminalCursorBlinkEnabled
        self.customTerminalTheme = customTerminalTheme
        if let aiProviderSettings {
            self.aiProviderSettings = AIProviderSettingsNormalizer.normalized(aiProviderSettings)
        } else if let profile = AIProviderProfile.recognizedProfile(for: aiProvider),
                  profile.usesModelInterface {
            let provider = legacyAIProviderConfiguration(
                id: compatibilityAIProviderID,
                profile: profile,
                baseURL: aiBaseURL,
                model: aiModel,
                customModels: aiCustomModels,
                compatibilityProtocol: aiCompatibilityProtocol,
                maxRetryCount: aiMaxRetryCount,
                requestTimeoutSeconds: aiRequestTimeoutSeconds,
                userAgent: aiUserAgent
            )
            self.aiProviderSettings = AIProviderSettingsNormalizer.normalized(
                .init(aiProviders: [provider], defaultAIProviderID: provider.id)
            )
        } else {
            self.aiProviderSettings = .rulesOnly
        }
        self.aiReasoningEffort = aiReasoningEffort
        self.aiIncludeRecentTerminalTranscript = aiIncludeRecentTerminalTranscript
        self.aiContextCharacterLimit = Self.clampedAIContextCharacterLimit(aiContextCharacterLimit)
        self.agentConfirmationPolicy = agentConfirmationPolicy
        self.agentExecutionMode = agentExecutionMode
        self.aiAutoRunProposedCommands = aiAutoRunProposedCommands
        self.agentCommandAllowPatterns = agentCommandAllowPatterns
        self.agentCommandDenyPatterns = agentCommandDenyPatterns
        self.filesDirectoryFollowDefault = filesDirectoryFollowDefault
        self.filesShowHiddenFilesByDefault = filesShowHiddenFilesByDefault
        self.filesRemoteEditAutoDetectChanges = filesRemoteEditAutoDetectChanges
        self.filesTransferConflictPolicy = filesTransferConflictPolicy
        self.filesTransferQueueVisibleByDefault = filesTransferQueueVisibleByDefault
        self.deviceMetricsRefreshIntervalSeconds = Self.clampedDeviceMetricsRefreshIntervalSeconds(deviceMetricsRefreshIntervalSeconds)
        self.deviceMetricsKeepLastSnapshotOnFailure = deviceMetricsKeepLastSnapshotOnFailure
        self.deviceMetricsShowNetworkSection = deviceMetricsShowNetworkSection
        self.deviceMetricsShowDiskSection = deviceMetricsShowDiskSection
        self.deviceMetricsDiskMountLimit = Self.clampedDeviceMetricsDiskMountLimit(deviceMetricsDiskMountLimit)
        self.deviceMetricsHideVirtualNetworkInterfaces = deviceMetricsHideVirtualNetworkInterfaces
        self.deviceMetricsHistorySampleCount = Self.clampedDeviceMetricsHistorySampleCount(deviceMetricsHistorySampleCount)
        self.deviceMetricsAlertEnabled = deviceMetricsAlertEnabled
        self.deviceMetricsCPUAlertThresholdPercent = Self.normalizedDeviceMetricsAlertThresholdPercent(deviceMetricsCPUAlertThresholdPercent)
        self.deviceMetricsMemoryAlertThresholdPercent = Self.normalizedDeviceMetricsAlertThresholdPercent(deviceMetricsMemoryAlertThresholdPercent)
        self.deviceMetricsDiskAlertThresholdPercent = Self.normalizedDeviceMetricsAlertThresholdPercent(deviceMetricsDiskAlertThresholdPercent)
        self.deviceMetricsAlertConsecutiveRefreshCount = Self.clampedDeviceMetricsAlertConsecutiveRefreshCount(deviceMetricsAlertConsecutiveRefreshCount)
        self.diagnosticsAuditExportLimit = Self.clampedDiagnosticsAuditExportLimit(diagnosticsAuditExportLimit)
        self.diagnosticsAppLogLineLimit = Self.clampedDiagnosticsAppLogLineLimit(diagnosticsAppLogLineLimit)
        self.diagnosticsIncludeAppLogs = diagnosticsIncludeAppLogs
    }

    private var selectedAIProviderIndex: Int? {
        guard aiProviderSettings.defaultAIProviderID != BuiltInAIProvider.stacioRulesID else {
            return nil
        }
        return aiProviderSettings.aiProviders.firstIndex {
            $0.id == aiProviderSettings.defaultAIProviderID
        }
    }

    private var selectedAIProvider: AIProviderConfiguration? {
        guard let index = selectedAIProviderIndex else { return nil }
        return aiProviderSettings.aiProviders[index]
    }

    public static func clampedAIRetryCount(_ value: Int) -> Int {
        min(max(value, 0), 5)
    }

    public static func normalizedAIUserAgent(_ value: String) -> String {
        let withoutControls = String(
            value.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
            }
        )
        let cleaned = withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return cleaned.isEmpty ? "Stacio" : cleaned
    }

    public static func normalizedAIModelName(_ value: String) -> String {
        let withoutControls = String(
            value.unicodeScalars.map { scalar in
                CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
            }
        )
        return withoutControls
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    public static func clampedAITimeoutSeconds(_ value: Int) -> Int {
        min(max(value, 5), 120)
    }

    public static func clampedAIContextCharacterLimit(_ value: Int) -> Int {
        min(max(value, 0), 24_000)
    }

    public static let defaultTerminalCommandSuggestionWordSeparators = "()[]{}\"':=,;|&<>"

    public static func clampedTerminalScrollbackLines(_ value: Int) -> Int {
        min(max(value, 100), 100_000)
    }

    public static func clampedTerminalKeepAliveIntervalSeconds(_ value: Int) -> Int {
        min(max(value, 0), 600)
    }

    public static func normalizedTerminalX11Display(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        })
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func clampedTerminalCommandSuggestionHistoryMinLength(_ value: Int) -> Int {
        min(max(value, 1), 64)
    }

    public static func clampedTerminalCommandSuggestionHistoryMaxLength(_ value: Int) -> Int {
        min(max(value, 1), 256)
    }

    public static func normalizedTerminalCommandSuggestionWordSeparators(_ value: String) -> String {
        let cleaned = String(value.unicodeScalars.filter { scalar in
            CharacterSet.controlCharacters.contains(scalar) == false
        })
        return cleaned.isEmpty ? defaultTerminalCommandSuggestionWordSeparators : cleaned
    }

    public static func clampedTerminalDuplicateSessionCommandDelayMilliseconds(_ value: Int) -> Int {
        min(max(value, 0), 60_000)
    }

    public static func clampedTerminalCommandCompletionNotificationThresholdSeconds(_ value: Int) -> Int {
        min(max(value, 1), 3_600)
    }

    public static func clampedDeviceMetricsRefreshIntervalSeconds(_ value: Int) -> Int {
        min(max(value, 1), 30)
    }

    public static func clampedDeviceMetricsDiskMountLimit(_ value: Int) -> Int {
        min(max(value, 1), 20)
    }

    public static func clampedDeviceMetricsHistorySampleCount(_ value: Int) -> Int {
        min(max(value, 3), 240)
    }

    public static func normalizedDeviceMetricsAlertThresholdPercent(_ value: Int) -> Int {
        (0...100).contains(value) ? value : 90
    }

    public static func clampedDeviceMetricsAlertConsecutiveRefreshCount(_ value: Int) -> Int {
        min(max(value, 1), 10)
    }

    public static func clampedDiagnosticsAuditExportLimit(_ value: Int) -> Int {
        min(max(value, 1), 500)
    }

    public static func clampedDiagnosticsAppLogLineLimit(_ value: Int) -> Int {
        min(max(value, 0), 2_000)
    }

    public static func normalizedAIModelList(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let model = normalizedAIModelName(value)
            guard model.isEmpty == false,
                  seen.insert(model).inserted
            else {
                return nil
            }
            return model
        }
    }
}

public final class AppSettingsStore: AIProviderSettingsStoring {
    public static let didChangeNotification = Notification.Name("Stacio.AppSettingsStore.didChange")
    public static let aiProviderSettingsDefaultsKey = "Stacio.Settings.aiProviderSettings"

    private struct AIProviderSettingsVersionHeader: Decodable {
        let formatVersion: Int
    }

    private enum Key {
        static let terminalFontSize = "Stacio.Settings.terminalFontSize"
        static let terminalFontFamily = "Stacio.Settings.terminalFontFamily"
        static let terminalTheme = "Stacio.Settings.terminalTheme"
        static let sessionTabIconMode = "Stacio.Settings.sessionTabIconMode"
        static let terminalBuiltInThemeID = "Stacio.Settings.terminalBuiltInThemeID"
        static let terminalCloseConfirmationEnabled = "Stacio.Settings.terminalCloseConfirmationEnabled"
        static let terminalSelectionAutoCopyEnabled = "Stacio.Settings.terminalSelectionAutoCopyEnabled"
        static let terminalRightClickBehavior = "Stacio.Settings.terminalRightClickBehavior"
        static let terminalHighlightLevel = "Stacio.Settings.terminalHighlightLevel"
        static let terminalRichHighlightingEnabled = "Stacio.Settings.terminalRichHighlightingEnabled"
        static let terminalControlScrollZoomEnabled = "Stacio.Settings.terminalControlScrollZoomEnabled"
        static let terminalScrollbackLines = "Stacio.Settings.terminalScrollbackLines"
        static let terminalKeepAliveIntervalSeconds = "Stacio.Settings.terminalKeepAliveIntervalSeconds"
        static let terminalX11Display = "Stacio.Settings.terminalX11Display"
        static let terminalHardwareAccelerationEnabled = "Stacio.Settings.terminalHardwareAccelerationEnabled"
        static let terminalWorkspacePaddingEnabled = "Stacio.Settings.terminalWorkspacePaddingEnabled"
        static let terminalLineNumbersEnabled = "Stacio.Settings.terminalLineNumbersEnabled"
        static let terminalTimestampsEnabled = "Stacio.Settings.terminalTimestampsEnabled"
        static let terminalTimestampMillisecondsEnabled = "Stacio.Settings.terminalTimestampMillisecondsEnabled"
        static let terminalMultiLinePasteConfirmationEnabled = "Stacio.Settings.terminalMultiLinePasteConfirmationEnabled"
        static let terminalPasteImageAsPathEnabled = "Stacio.Settings.terminalPasteImageAsPathEnabled"
        static let terminalAltAsMetaEnabled = "Stacio.Settings.terminalAltAsMetaEnabled"
        static let terminalMacIMECompatibilityEnabled = "Stacio.Settings.terminalMacIMECompatibilityEnabled"
        static let terminalCommandSuggestionEnabled = "Stacio.Settings.terminalCommandSuggestionEnabled"
        static let terminalCommandSuggestionHistoryMinLength = "Stacio.Settings.terminalCommandSuggestionHistoryMinLength"
        static let terminalCommandSuggestionHistoryMaxLength = "Stacio.Settings.terminalCommandSuggestionHistoryMaxLength"
        static let terminalCommandSuggestionWordSeparators = "Stacio.Settings.terminalCommandSuggestionWordSeparators"
        static let terminalDuplicateSessionCommandDelayMilliseconds = "Stacio.Settings.terminalDuplicateSessionCommandDelayMilliseconds"
        static let legacyTerminalPasteCommandExecutionDelayMilliseconds = "Stacio.Settings.terminalPasteCommandExecutionDelayMilliseconds"
        static let terminalCommandCompletionNotificationEnabled = "Stacio.Settings.terminalCommandCompletionNotificationEnabled"
        static let terminalCommandCompletionNotificationThresholdSeconds = "Stacio.Settings.terminalCommandCompletionNotificationThresholdSeconds"
        static let terminalCursorShape = "Stacio.Settings.terminalCursorShape"
        static let terminalCursorBlinkEnabled = "Stacio.Settings.terminalCursorBlinkEnabled"
        static let customTerminalTheme = "Stacio.Settings.customTerminalTheme"
        static let aiProvider = "Stacio.Settings.aiProvider"
        static let aiBaseURL = "Stacio.Settings.aiBaseURL"
        static let aiModel = "Stacio.Settings.aiModel"
        static let aiMaxRetryCount = "Stacio.Settings.aiMaxRetryCount"
        static let aiUserAgent = "Stacio.Settings.aiUserAgent"
        static let aiRequestTimeoutSeconds = "Stacio.Settings.aiRequestTimeoutSeconds"
        static let aiCustomModels = "Stacio.Settings.aiCustomModels"
        static let aiReasoningEffort = "Stacio.Settings.aiReasoningEffort"
        static let aiCompatibilityProtocol = "Stacio.Settings.aiCompatibilityProtocol"
        static let aiIncludeRecentTerminalTranscript = "Stacio.Settings.aiIncludeRecentTerminalTranscript"
        static let aiContextCharacterLimit = "Stacio.Settings.aiContextCharacterLimit"
        static let agentConfirmationPolicy = "Stacio.Settings.agentConfirmationPolicy"
        static let agentExecutionMode = "Stacio.Settings.agentExecutionMode"
        static let aiAutoRunProposedCommands = "Stacio.Settings.aiAutoRunProposedCommands"
        static let agentCommandAllowPatterns = "Stacio.Settings.agentCommandAllowPatterns"
        static let agentCommandDenyPatterns = "Stacio.Settings.agentCommandDenyPatterns"
        static let filesDirectoryFollowDefault = "Stacio.Settings.filesDirectoryFollowDefault"
        static let filesShowHiddenFilesByDefault = "Stacio.Settings.filesShowHiddenFilesByDefault"
        static let filesRemoteEditAutoDetectChanges = "Stacio.Settings.filesRemoteEditAutoDetectChanges"
        static let filesTransferConflictPolicy = "Stacio.Settings.filesTransferConflictPolicy"
        static let filesTransferQueueVisibleByDefault = "Stacio.Settings.filesTransferQueueVisibleByDefault"
        static let deviceMetricsRefreshIntervalSeconds = "Stacio.Settings.deviceMetricsRefreshIntervalSeconds"
        static let deviceMetricsKeepLastSnapshotOnFailure = "Stacio.Settings.deviceMetricsKeepLastSnapshotOnFailure"
        static let deviceMetricsShowNetworkSection = "Stacio.Settings.deviceMetricsShowNetworkSection"
        static let deviceMetricsShowDiskSection = "Stacio.Settings.deviceMetricsShowDiskSection"
        static let deviceMetricsDiskMountLimit = "Stacio.Settings.deviceMetricsDiskMountLimit"
        static let deviceMetricsHideVirtualNetworkInterfaces = "Stacio.Settings.deviceMetricsHideVirtualNetworkInterfaces"
        static let deviceMetricsHistorySampleCount = "Stacio.Settings.deviceMetricsHistorySampleCount"
        static let deviceMetricsAlertEnabled = "Stacio.Settings.deviceMetricsAlertEnabled"
        static let deviceMetricsCPUAlertThresholdPercent = "Stacio.Settings.deviceMetricsCPUAlertThresholdPercent"
        static let deviceMetricsMemoryAlertThresholdPercent = "Stacio.Settings.deviceMetricsMemoryAlertThresholdPercent"
        static let deviceMetricsDiskAlertThresholdPercent = "Stacio.Settings.deviceMetricsDiskAlertThresholdPercent"
        static let deviceMetricsAlertConsecutiveRefreshCount = "Stacio.Settings.deviceMetricsAlertConsecutiveRefreshCount"
        static let diagnosticsAuditExportLimit = "Stacio.Settings.diagnosticsAuditExportLimit"
        static let diagnosticsAppLogLineLimit = "Stacio.Settings.diagnosticsAppLogLineLimit"
        static let diagnosticsIncludeAppLogs = "Stacio.Settings.diagnosticsIncludeAppLogs"
    }

    public static let shared = AppSettingsStore()
    private static let aiProviderSettingsLock = NSLock()

    private let defaults: UserDefaults
    private let aiProviderIDGenerator: () -> UUID

    public init(
        defaults: UserDefaults = .standard,
        aiProviderIDGenerator: @escaping () -> UUID = UUID.init
    ) {
        self.defaults = defaults
        self.aiProviderIDGenerator = aiProviderIDGenerator
    }

    public func snapshot() -> AppSettings {
        let fontSize = defaults.object(forKey: Key.terminalFontSize) as? Double ?? 13
        let rawFontFamily = defaults.string(forKey: Key.terminalFontFamily)
            ?? TerminalFontFamilyPreference.sfMono.rawValue
        let rawTheme = defaults.string(forKey: Key.terminalTheme) ?? TerminalThemePreference.system.rawValue
        let rawSessionTabIconMode = defaults.string(forKey: Key.sessionTabIconMode)
            ?? SessionTabIconModePreference.defaultIcon.rawValue
        let rawBuiltInThemeID = defaults.string(forKey: Key.terminalBuiltInThemeID)
        let rawRightClickBehavior = defaults.string(forKey: Key.terminalRightClickBehavior)
            ?? TerminalRightClickBehaviorPreference.paste.rawValue
        let rawHighlightLevel = defaults.string(forKey: Key.terminalHighlightLevel)
            ?? TerminalHighlightLevelPreference.commandLineEnhanced.rawValue
        let rawCursorShape = defaults.string(forKey: Key.terminalCursorShape)
            ?? TerminalCursorShapePreference.block.rawValue
        let terminalScrollbackLines = defaults.object(forKey: Key.terminalScrollbackLines) as? Int ?? 10_000
        let terminalKeepAliveIntervalSeconds = defaults.object(forKey: Key.terminalKeepAliveIntervalSeconds) as? Int ?? 60
        let terminalCommandSuggestionHistoryMinLength = defaults.object(
            forKey: Key.terminalCommandSuggestionHistoryMinLength
        ) as? Int ?? 2
        let terminalCommandSuggestionHistoryMaxLength = defaults.object(
            forKey: Key.terminalCommandSuggestionHistoryMaxLength
        ) as? Int ?? 64
        let terminalCommandSuggestionWordSeparators = defaults.string(
            forKey: Key.terminalCommandSuggestionWordSeparators
        ) ?? AppSettings.defaultTerminalCommandSuggestionWordSeparators
        let terminalDuplicateSessionCommandDelayMilliseconds = (
            defaults.object(forKey: Key.terminalDuplicateSessionCommandDelayMilliseconds)
                ?? defaults.object(forKey: Key.legacyTerminalPasteCommandExecutionDelayMilliseconds)
        ) as? Int ?? 1_000
        let terminalCommandCompletionNotificationThresholdSeconds = defaults.object(
            forKey: Key.terminalCommandCompletionNotificationThresholdSeconds
        ) as? Int ?? 5
        let customTheme = defaults.data(forKey: Key.customTerminalTheme)
            .flatMap { try? JSONDecoder().decode(TerminalColorTheme.self, from: $0) }
        let aiProviderSettings = (try? loadAIProviderSettings()) ?? .rulesOnly
        let rawReasoningEffort = defaults.string(forKey: Key.aiReasoningEffort)
            ?? AIReasoningEffortPreference.medium.rawValue
        let contextCharacterLimit = defaults.object(forKey: Key.aiContextCharacterLimit) as? Int ?? 12_000
        let rawConfirmationPolicy = defaults.string(forKey: Key.agentConfirmationPolicy)
            ?? AgentConfirmationPolicyPreference.allowLowRiskWithoutPrompt.rawValue
        let rawExecutionMode = defaults.string(forKey: Key.agentExecutionMode)
            ?? AgentExecutionModePreference.backgroundTask.rawValue
        let rawFilesTransferConflictPolicy = defaults.string(forKey: Key.filesTransferConflictPolicy)
            ?? FilesTransferConflictPolicyPreference.ask.rawValue
        let deviceMetricsRefreshIntervalSeconds = defaults.object(forKey: Key.deviceMetricsRefreshIntervalSeconds) as? Int ?? 2
        let deviceMetricsDiskMountLimit = defaults.object(forKey: Key.deviceMetricsDiskMountLimit) as? Int ?? 5
        let deviceMetricsHistorySampleCount = defaults.object(forKey: Key.deviceMetricsHistorySampleCount) as? Int ?? 42
        let deviceMetricsCPUAlertThresholdPercent = defaults.object(forKey: Key.deviceMetricsCPUAlertThresholdPercent) as? Int ?? 90
        let deviceMetricsMemoryAlertThresholdPercent = defaults.object(forKey: Key.deviceMetricsMemoryAlertThresholdPercent) as? Int ?? 90
        let deviceMetricsDiskAlertThresholdPercent = defaults.object(forKey: Key.deviceMetricsDiskAlertThresholdPercent) as? Int ?? 90
        let deviceMetricsAlertConsecutiveRefreshCount = defaults.object(forKey: Key.deviceMetricsAlertConsecutiveRefreshCount) as? Int ?? 2
        let diagnosticsAuditExportLimit = defaults.object(forKey: Key.diagnosticsAuditExportLimit) as? Int ?? 20
        let diagnosticsAppLogLineLimit = defaults.object(forKey: Key.diagnosticsAppLogLineLimit) as? Int ?? 200
        return AppSettings(
            terminalFontSize: min(max(fontSize, 9), 28),
            terminalFontFamily: TerminalFontFamilyPreference(rawValue: rawFontFamily) ?? .sfMono,
            terminalTheme: TerminalThemePreference(rawValue: rawTheme) ?? .system,
            sessionTabIconMode: SessionTabIconModePreference(rawValue: rawSessionTabIconMode) ?? .defaultIcon,
            terminalBuiltInThemeID: TerminalColorTheme.resolvedBuiltInTheme(id: rawBuiltInThemeID).id ?? "stacio-dark",
            terminalCloseConfirmationEnabled: defaults.object(forKey: Key.terminalCloseConfirmationEnabled) as? Bool ?? true,
            terminalSelectionAutoCopyEnabled: defaults.object(forKey: Key.terminalSelectionAutoCopyEnabled) as? Bool ?? true,
            terminalRightClickBehavior: TerminalRightClickBehaviorPreference(rawValue: rawRightClickBehavior) ?? .paste,
            terminalHighlightLevel: TerminalHighlightLevelPreference(rawValue: rawHighlightLevel) ?? .ansiOnly,
            terminalRichHighlightingEnabled: defaults.object(forKey: Key.terminalRichHighlightingEnabled) as? Bool ?? true,
            terminalControlScrollZoomEnabled: defaults.object(forKey: Key.terminalControlScrollZoomEnabled) as? Bool ?? true,
            terminalScrollbackLines: terminalScrollbackLines,
            terminalKeepAliveIntervalSeconds: terminalKeepAliveIntervalSeconds,
            terminalX11Display: defaults.string(forKey: Key.terminalX11Display) ?? "",
            terminalHardwareAccelerationEnabled: defaults.object(forKey: Key.terminalHardwareAccelerationEnabled) as? Bool ?? false,
            terminalWorkspacePaddingEnabled: defaults.object(forKey: Key.terminalWorkspacePaddingEnabled) as? Bool ?? false,
            terminalLineNumbersEnabled: defaults.object(forKey: Key.terminalLineNumbersEnabled) as? Bool ?? false,
            terminalTimestampsEnabled: defaults.object(forKey: Key.terminalTimestampsEnabled) as? Bool ?? false,
            terminalTimestampMillisecondsEnabled: defaults.object(forKey: Key.terminalTimestampMillisecondsEnabled) as? Bool ?? false,
            terminalMultiLinePasteConfirmationEnabled: defaults.object(forKey: Key.terminalMultiLinePasteConfirmationEnabled) as? Bool ?? true,
            terminalPasteImageAsPathEnabled: defaults.object(forKey: Key.terminalPasteImageAsPathEnabled) as? Bool ?? true,
            terminalAltAsMetaEnabled: defaults.object(forKey: Key.terminalAltAsMetaEnabled) as? Bool ?? false,
            terminalMacIMECompatibilityEnabled: defaults.object(forKey: Key.terminalMacIMECompatibilityEnabled) as? Bool ?? false,
            terminalCommandSuggestionEnabled: defaults.object(forKey: Key.terminalCommandSuggestionEnabled) as? Bool ?? true,
            terminalCommandSuggestionHistoryMinLength: terminalCommandSuggestionHistoryMinLength,
            terminalCommandSuggestionHistoryMaxLength: terminalCommandSuggestionHistoryMaxLength,
            terminalCommandSuggestionWordSeparators: terminalCommandSuggestionWordSeparators,
            terminalDuplicateSessionCommandDelayMilliseconds: terminalDuplicateSessionCommandDelayMilliseconds,
            terminalCommandCompletionNotificationEnabled: defaults.object(forKey: Key.terminalCommandCompletionNotificationEnabled) as? Bool ?? true,
            terminalCommandCompletionNotificationThresholdSeconds: terminalCommandCompletionNotificationThresholdSeconds,
            terminalCursorShape: TerminalCursorShapePreference(rawValue: rawCursorShape) ?? .block,
            terminalCursorBlinkEnabled: defaults.object(forKey: Key.terminalCursorBlinkEnabled) as? Bool ?? true,
            customTerminalTheme: customTheme,
            aiProviderSettings: aiProviderSettings,
            aiReasoningEffort: AIReasoningEffortPreference(rawValue: rawReasoningEffort) ?? .medium,
            aiIncludeRecentTerminalTranscript: defaults.object(forKey: Key.aiIncludeRecentTerminalTranscript) as? Bool ?? true,
            aiContextCharacterLimit: contextCharacterLimit,
            agentConfirmationPolicy: AgentConfirmationPolicyPreference.fromStoredRawValue(rawConfirmationPolicy),
            agentExecutionMode: AgentExecutionModePreference(rawValue: rawExecutionMode) ?? .backgroundTask,
            aiAutoRunProposedCommands: defaults.object(forKey: Key.aiAutoRunProposedCommands) as? Bool ?? true,
            agentCommandAllowPatterns: defaults.string(forKey: Key.agentCommandAllowPatterns) ?? "",
            agentCommandDenyPatterns: defaults.string(forKey: Key.agentCommandDenyPatterns) ?? "",
            filesDirectoryFollowDefault: defaults.object(forKey: Key.filesDirectoryFollowDefault) as? Bool ?? true,
            filesShowHiddenFilesByDefault: defaults.object(forKey: Key.filesShowHiddenFilesByDefault) as? Bool ?? true,
            filesRemoteEditAutoDetectChanges: defaults.object(forKey: Key.filesRemoteEditAutoDetectChanges) as? Bool ?? true,
            filesTransferConflictPolicy: FilesTransferConflictPolicyPreference(rawValue: rawFilesTransferConflictPolicy) ?? .ask,
            filesTransferQueueVisibleByDefault: defaults.object(forKey: Key.filesTransferQueueVisibleByDefault) as? Bool ?? true,
            deviceMetricsRefreshIntervalSeconds: deviceMetricsRefreshIntervalSeconds,
            deviceMetricsKeepLastSnapshotOnFailure: defaults.object(forKey: Key.deviceMetricsKeepLastSnapshotOnFailure) as? Bool ?? true,
            deviceMetricsShowNetworkSection: defaults.object(forKey: Key.deviceMetricsShowNetworkSection) as? Bool ?? true,
            deviceMetricsShowDiskSection: defaults.object(forKey: Key.deviceMetricsShowDiskSection) as? Bool ?? true,
            deviceMetricsDiskMountLimit: deviceMetricsDiskMountLimit,
            deviceMetricsHideVirtualNetworkInterfaces: defaults.object(forKey: Key.deviceMetricsHideVirtualNetworkInterfaces) as? Bool ?? true,
            deviceMetricsHistorySampleCount: deviceMetricsHistorySampleCount,
            deviceMetricsAlertEnabled: defaults.object(forKey: Key.deviceMetricsAlertEnabled) as? Bool ?? true,
            deviceMetricsCPUAlertThresholdPercent: deviceMetricsCPUAlertThresholdPercent,
            deviceMetricsMemoryAlertThresholdPercent: deviceMetricsMemoryAlertThresholdPercent,
            deviceMetricsDiskAlertThresholdPercent: deviceMetricsDiskAlertThresholdPercent,
            deviceMetricsAlertConsecutiveRefreshCount: deviceMetricsAlertConsecutiveRefreshCount,
            diagnosticsAuditExportLimit: diagnosticsAuditExportLimit,
            diagnosticsAppLogLineLimit: diagnosticsAppLogLineLimit,
            diagnosticsIncludeAppLogs: defaults.object(forKey: Key.diagnosticsIncludeAppLogs) as? Bool ?? true
        )
    }

    public func loadAIProviderSettings() throws -> AIProviderSettingsEnvelope {
        let result = try withAIProviderSettingsLock { () -> (
            envelope: AIProviderSettingsEnvelope,
            didPersistMigration: Bool
        ) in
            if let data = defaults.data(forKey: Self.aiProviderSettingsDefaultsKey) {
                let decoder = JSONDecoder()
                let header = try decoder.decode(AIProviderSettingsVersionHeader.self, from: data)
                guard header.formatVersion == AIProviderSettingsEnvelope.currentFormatVersion else {
                    throw AIProviderSettingsStoreError.unsupportedVersion(header.formatVersion)
                }
                let decoded = try decoder.decode(AIProviderSettingsEnvelope.self, from: data)
                let normalized = AIProviderSettingsNormalizer.normalized(decoded)
                let migrated = migrateMissingModelCapabilitiesIfNeeded(
                    normalized,
                    rawEnvelopeData: data
                )
                if migrated != normalized {
                    try persistAIProviderSettings(migrated)
                    return (migrated, true)
                }
                return (normalized, false)
            }

            let migrated = migrateLegacyAIProviderSettings()
            try persistAIProviderSettings(migrated)
            return (migrated, true)
        }
        if result.didPersistMigration {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        return result.envelope
    }

    public func saveAIProviderSettings(_ envelope: AIProviderSettingsEnvelope) throws {
        try withAIProviderSettingsLock {
            try persistAIProviderSettings(envelope)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func persistAIProviderSettings(_ envelope: AIProviderSettingsEnvelope) throws {
        guard envelope.formatVersion == AIProviderSettingsEnvelope.currentFormatVersion else {
            throw AIProviderSettingsStoreError.unsupportedVersion(envelope.formatVersion)
        }
        let normalized = AIProviderSettingsNormalizer.normalized(envelope)
        let data = try JSONEncoder().encode(normalized)
        defaults.set(data, forKey: Self.aiProviderSettingsDefaultsKey)
        guard defaults.data(forKey: Self.aiProviderSettingsDefaultsKey) == data else {
            throw AIProviderSettingsStoreError.writeVerificationFailed
        }
    }

    private func withAIProviderSettingsLock<T>(_ operation: () throws -> T) rethrows -> T {
        Self.aiProviderSettingsLock.lock()
        defer { Self.aiProviderSettingsLock.unlock() }
        return try operation()
    }

    private func migrateLegacyAIProviderSettings() -> AIProviderSettingsEnvelope {
        let legacyProvider = defaults.string(forKey: Key.aiProvider)
            ?? AIProviderProfile.portDeskRules.rawValue
        guard let profile = AIProviderProfile.recognizedProfile(for: legacyProvider),
              profile.usesModelInterface
        else {
            return .rulesOnly
        }

        let providerID = aiProviderIDGenerator()
        let rawCompatibilityProtocol = defaults.string(forKey: Key.aiCompatibilityProtocol)
            ?? AICompatibilityProtocolPreference.chatCompletions.rawValue
        let legacyReasoningEffort = AIReasoningEffortPreference(
            rawValue: defaults.string(forKey: Key.aiReasoningEffort)
                ?? AIReasoningEffortPreference.medium.rawValue
        )
        let legacyContextCharacterLimit = defaults.object(
            forKey: Key.aiContextCharacterLimit
        ) as? Int ?? AIModelCapabilityConfiguration.defaultContextCharacterLimit
        let provider = legacyAIProviderConfiguration(
            id: providerID,
            profile: profile,
            baseURL: defaults.string(forKey: Key.aiBaseURL) ?? "",
            model: defaults.string(forKey: Key.aiModel) ?? "",
            customModels: defaults.stringArray(forKey: Key.aiCustomModels) ?? [],
            compatibilityProtocol: AICompatibilityProtocolPreference(rawValue: rawCompatibilityProtocol)
                ?? .chatCompletions,
            maxRetryCount: defaults.object(forKey: Key.aiMaxRetryCount) as? Int ?? 1,
            requestTimeoutSeconds: defaults.object(forKey: Key.aiRequestTimeoutSeconds) as? Int ?? 45,
            userAgent: defaults.string(forKey: Key.aiUserAgent) ?? "Stacio",
            legacyReasoningEffort: legacyReasoningEffort,
            legacyContextCharacterLimit: legacyContextCharacterLimit
        )
        return AIProviderSettingsNormalizer.normalized(
            .init(
                aiProviders: [provider],
                defaultAIProviderID: providerID,
                legacyKeyMigrationProviderID: providerID
            )
        )
    }

    private func migrateMissingModelCapabilitiesIfNeeded(
        _ envelope: AIProviderSettingsEnvelope,
        rawEnvelopeData: Data
    ) -> AIProviderSettingsEnvelope {
        guard envelopeContainsModelsWithoutCapabilities(rawEnvelopeData) else {
            return envelope
        }
        let legacyReasoningEffort = AIReasoningEffortPreference(
            rawValue: defaults.string(forKey: Key.aiReasoningEffort)
                ?? AIReasoningEffortPreference.medium.rawValue
        )
        let legacyContextCharacterLimit = defaults.object(
            forKey: Key.aiContextCharacterLimit
        ) as? Int ?? AIModelCapabilityConfiguration.defaultContextCharacterLimit
        var migrated = envelope
        for providerIndex in migrated.aiProviders.indices {
            for modelIndex in migrated.aiProviders[providerIndex].models.indices {
                var model = migrated.aiProviders[providerIndex].models[modelIndex]
                guard model.capabilities.contextCharacterLimitSource == .unknown,
                      model.capabilities.contextCharacterLimit == nil,
                      model.capabilities.reasoningEffortSource == .unknown,
                      model.capabilities.reasoningEffort == nil
                else {
                    continue
                }
                model.capabilities = legacyCapabilities(
                    reasoningEffort: legacyReasoningEffort,
                    contextCharacterLimit: legacyContextCharacterLimit
                )
                migrated.aiProviders[providerIndex].models[modelIndex] = model
            }
        }
        return AIProviderSettingsNormalizer.normalized(migrated)
    }

    private func envelopeContainsModelsWithoutCapabilities(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["aiProviders"] as? [[String: Any]]
        else {
            return false
        }
        return providers.contains { provider in
            guard let models = provider["models"] as? [[String: Any]] else {
                return false
            }
            return models.contains { $0["capabilities"] == nil }
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var settings = snapshot()
        mutate(&settings)
        defaults.set(min(max(settings.terminalFontSize, 9), 28), forKey: Key.terminalFontSize)
        defaults.set(settings.terminalFontFamily.rawValue, forKey: Key.terminalFontFamily)
        defaults.set(settings.terminalTheme.rawValue, forKey: Key.terminalTheme)
        defaults.set(settings.sessionTabIconMode.rawValue, forKey: Key.sessionTabIconMode)
        defaults.set(TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID).id, forKey: Key.terminalBuiltInThemeID)
        defaults.set(settings.terminalCloseConfirmationEnabled, forKey: Key.terminalCloseConfirmationEnabled)
        defaults.set(settings.terminalSelectionAutoCopyEnabled, forKey: Key.terminalSelectionAutoCopyEnabled)
        defaults.set(settings.terminalRightClickBehavior.rawValue, forKey: Key.terminalRightClickBehavior)
        defaults.set(settings.terminalHighlightLevel.rawValue, forKey: Key.terminalHighlightLevel)
        defaults.set(settings.terminalRichHighlightingEnabled, forKey: Key.terminalRichHighlightingEnabled)
        defaults.set(settings.terminalControlScrollZoomEnabled, forKey: Key.terminalControlScrollZoomEnabled)
        defaults.set(AppSettings.clampedTerminalScrollbackLines(settings.terminalScrollbackLines), forKey: Key.terminalScrollbackLines)
        defaults.set(AppSettings.clampedTerminalKeepAliveIntervalSeconds(settings.terminalKeepAliveIntervalSeconds), forKey: Key.terminalKeepAliveIntervalSeconds)
        defaults.set(AppSettings.normalizedTerminalX11Display(settings.terminalX11Display), forKey: Key.terminalX11Display)
        defaults.set(settings.terminalHardwareAccelerationEnabled, forKey: Key.terminalHardwareAccelerationEnabled)
        defaults.set(settings.terminalWorkspacePaddingEnabled, forKey: Key.terminalWorkspacePaddingEnabled)
        defaults.set(settings.terminalLineNumbersEnabled, forKey: Key.terminalLineNumbersEnabled)
        defaults.set(settings.terminalTimestampsEnabled, forKey: Key.terminalTimestampsEnabled)
        defaults.set(settings.terminalTimestampMillisecondsEnabled, forKey: Key.terminalTimestampMillisecondsEnabled)
        defaults.set(settings.terminalMultiLinePasteConfirmationEnabled, forKey: Key.terminalMultiLinePasteConfirmationEnabled)
        defaults.set(settings.terminalPasteImageAsPathEnabled, forKey: Key.terminalPasteImageAsPathEnabled)
        defaults.set(settings.terminalAltAsMetaEnabled, forKey: Key.terminalAltAsMetaEnabled)
        defaults.set(settings.terminalMacIMECompatibilityEnabled, forKey: Key.terminalMacIMECompatibilityEnabled)
        defaults.set(settings.terminalCommandSuggestionEnabled, forKey: Key.terminalCommandSuggestionEnabled)
        let suggestionMinLength = AppSettings.clampedTerminalCommandSuggestionHistoryMinLength(settings.terminalCommandSuggestionHistoryMinLength)
        let suggestionMaxLength = max(
            suggestionMinLength,
            AppSettings.clampedTerminalCommandSuggestionHistoryMaxLength(settings.terminalCommandSuggestionHistoryMaxLength)
        )
        defaults.set(suggestionMinLength, forKey: Key.terminalCommandSuggestionHistoryMinLength)
        defaults.set(suggestionMaxLength, forKey: Key.terminalCommandSuggestionHistoryMaxLength)
        defaults.set(
            AppSettings.normalizedTerminalCommandSuggestionWordSeparators(settings.terminalCommandSuggestionWordSeparators),
            forKey: Key.terminalCommandSuggestionWordSeparators
        )
        defaults.set(
            AppSettings.clampedTerminalDuplicateSessionCommandDelayMilliseconds(
                settings.terminalDuplicateSessionCommandDelayMilliseconds
            ),
            forKey: Key.terminalDuplicateSessionCommandDelayMilliseconds
        )
        defaults.set(settings.terminalCommandCompletionNotificationEnabled, forKey: Key.terminalCommandCompletionNotificationEnabled)
        defaults.set(
            AppSettings.clampedTerminalCommandCompletionNotificationThresholdSeconds(
                settings.terminalCommandCompletionNotificationThresholdSeconds
            ),
            forKey: Key.terminalCommandCompletionNotificationThresholdSeconds
        )
        defaults.set(settings.terminalCursorShape.rawValue, forKey: Key.terminalCursorShape)
        defaults.set(settings.terminalCursorBlinkEnabled, forKey: Key.terminalCursorBlinkEnabled)
        if let customThemeData = try? JSONEncoder().encode(settings.customTerminalTheme) {
            defaults.set(customThemeData, forKey: Key.customTerminalTheme)
        } else {
            defaults.removeObject(forKey: Key.customTerminalTheme)
        }
        defaults.set(settings.aiReasoningEffort.rawValue, forKey: Key.aiReasoningEffort)
        defaults.set(settings.aiIncludeRecentTerminalTranscript, forKey: Key.aiIncludeRecentTerminalTranscript)
        defaults.set(AppSettings.clampedAIContextCharacterLimit(settings.aiContextCharacterLimit), forKey: Key.aiContextCharacterLimit)
        defaults.set(settings.agentConfirmationPolicy.rawValue, forKey: Key.agentConfirmationPolicy)
        defaults.set(settings.agentExecutionMode.rawValue, forKey: Key.agentExecutionMode)
        defaults.set(settings.aiAutoRunProposedCommands, forKey: Key.aiAutoRunProposedCommands)
        defaults.set(Self.normalizedCommandPatterns(settings.agentCommandAllowPatterns), forKey: Key.agentCommandAllowPatterns)
        defaults.set(Self.normalizedCommandPatterns(settings.agentCommandDenyPatterns), forKey: Key.agentCommandDenyPatterns)
        defaults.set(settings.filesDirectoryFollowDefault, forKey: Key.filesDirectoryFollowDefault)
        defaults.set(settings.filesShowHiddenFilesByDefault, forKey: Key.filesShowHiddenFilesByDefault)
        defaults.set(settings.filesRemoteEditAutoDetectChanges, forKey: Key.filesRemoteEditAutoDetectChanges)
        defaults.set(settings.filesTransferConflictPolicy.rawValue, forKey: Key.filesTransferConflictPolicy)
        defaults.set(settings.filesTransferQueueVisibleByDefault, forKey: Key.filesTransferQueueVisibleByDefault)
        defaults.set(AppSettings.clampedDeviceMetricsRefreshIntervalSeconds(settings.deviceMetricsRefreshIntervalSeconds), forKey: Key.deviceMetricsRefreshIntervalSeconds)
        defaults.set(settings.deviceMetricsKeepLastSnapshotOnFailure, forKey: Key.deviceMetricsKeepLastSnapshotOnFailure)
        defaults.set(settings.deviceMetricsShowNetworkSection, forKey: Key.deviceMetricsShowNetworkSection)
        defaults.set(settings.deviceMetricsShowDiskSection, forKey: Key.deviceMetricsShowDiskSection)
        defaults.set(AppSettings.clampedDeviceMetricsDiskMountLimit(settings.deviceMetricsDiskMountLimit), forKey: Key.deviceMetricsDiskMountLimit)
        defaults.set(settings.deviceMetricsHideVirtualNetworkInterfaces, forKey: Key.deviceMetricsHideVirtualNetworkInterfaces)
        defaults.set(AppSettings.clampedDeviceMetricsHistorySampleCount(settings.deviceMetricsHistorySampleCount), forKey: Key.deviceMetricsHistorySampleCount)
        defaults.set(settings.deviceMetricsAlertEnabled, forKey: Key.deviceMetricsAlertEnabled)
        defaults.set(AppSettings.normalizedDeviceMetricsAlertThresholdPercent(settings.deviceMetricsCPUAlertThresholdPercent), forKey: Key.deviceMetricsCPUAlertThresholdPercent)
        defaults.set(AppSettings.normalizedDeviceMetricsAlertThresholdPercent(settings.deviceMetricsMemoryAlertThresholdPercent), forKey: Key.deviceMetricsMemoryAlertThresholdPercent)
        defaults.set(AppSettings.normalizedDeviceMetricsAlertThresholdPercent(settings.deviceMetricsDiskAlertThresholdPercent), forKey: Key.deviceMetricsDiskAlertThresholdPercent)
        defaults.set(AppSettings.clampedDeviceMetricsAlertConsecutiveRefreshCount(settings.deviceMetricsAlertConsecutiveRefreshCount), forKey: Key.deviceMetricsAlertConsecutiveRefreshCount)
        defaults.set(AppSettings.clampedDiagnosticsAuditExportLimit(settings.diagnosticsAuditExportLimit), forKey: Key.diagnosticsAuditExportLimit)
        defaults.set(AppSettings.clampedDiagnosticsAppLogLineLimit(settings.diagnosticsAppLogLineLimit), forKey: Key.diagnosticsAppLogLineLimit)
        defaults.set(settings.diagnosticsIncludeAppLogs, forKey: Key.diagnosticsIncludeAppLogs)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private static func normalizedCommandPatterns(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "\n")
    }
}

public enum TerminalFontZoomController {
    @discardableResult
    public static func applyControlScrollZoom(
        deltaY: CGFloat,
        settingsStore: AppSettingsStore,
        terminalView: TerminalView
    ) -> Bool {
        guard deltaY != 0 else {
            return false
        }
        let delta = deltaY < 0 ? 1.0 : -1.0
        settingsStore.update { settings in
            settings.terminalFontSize += delta
        }
        TerminalAppearanceApplier.apply(settings: settingsStore.snapshot(), to: terminalView)
        return true
    }

    public static func handleControlScrollZoom(
        event: NSEvent,
        settingsStore: AppSettingsStore,
        terminalView: TerminalView
    ) -> Bool {
        guard event.modifierFlags.contains(.control) else {
            return false
        }
        return applyControlScrollZoom(
            deltaY: event.deltaY,
            settingsStore: settingsStore,
            terminalView: terminalView
        )
    }
}

public enum TerminalAppearanceApplier {
    public static func shouldEnableMetal(
        requested: Bool,
        bundleURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard requested else {
            return false
        }
        let shaderURL = bundleURL
            .appendingPathComponent("SwiftTerm_SwiftTerm.bundle", isDirectory: true)
            .appendingPathComponent("Shaders.metal", isDirectory: false)
        return fileManager.fileExists(atPath: shaderURL.path)
    }

    public static func highlightTheme(for settings: AppSettings) -> TerminalColorTheme {
        switch settings.terminalTheme {
        case .dark:
            return TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID)
        case .custom:
            return settings.customTerminalTheme ?? TerminalColorTheme.systemAdaptivePreview
        case .system, .light:
            return TerminalColorTheme.systemAdaptivePreview
        }
    }

    public static func apply(settings: AppSettings, to terminalView: TerminalView) {
        terminalView.font = font(for: settings)
        terminalView.optionAsMetaKey = settings.terminalAltAsMetaEnabled
        terminalView.changeScrollback(settings.terminalScrollbackLines)
        let useMetal = shouldEnableMetal(
            requested: settings.terminalHardwareAccelerationEnabled,
            bundleURL: Bundle.main.bundleURL
        )
        try? terminalView.setUseMetal(useMetal)
        terminalView.terminal.options.cursorStyle = cursorStyle(for: settings)
        terminalView.cursorStyleChanged(source: terminalView.terminal, newStyle: terminalView.terminal.options.cursorStyle)

        switch settings.terminalTheme {
        case .system:
            terminalView.nativeForegroundColor = StacioDesignSystem.resolvedColor(.textColor, for: terminalView)
            terminalView.nativeBackgroundColor = StacioDesignSystem.resolvedColor(.textBackgroundColor, for: terminalView)
            terminalView.caretColor = terminalView.nativeForegroundColor
            terminalView.selectedTextBackgroundColor = StacioDesignSystem.resolvedColor(
                .selectedTextBackgroundColor,
                for: terminalView
            )
        case .light:
            apply(theme: .solarizedLight, to: terminalView)
        case .dark:
            apply(theme: TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID), to: terminalView)
        case .custom:
            if let theme = settings.customTerminalTheme {
                apply(theme: theme, to: terminalView)
            } else {
                terminalView.configureNativeColors()
            }
        }
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = StacioDesignSystem.resolvedLayerColor(
            terminalView.nativeBackgroundColor,
            for: terminalView
        )
        if terminalView.frame.width > 0, terminalView.frame.height > 0 {
            terminalView.setFrameSize(terminalView.frame.size)
        }
        terminalView.terminal.updateFullScreen()
        terminalView.needsLayout = true
        terminalView.needsDisplay = true
    }

    public static func font(for settings: AppSettings) -> NSFont {
        let size = CGFloat(settings.terminalFontSize)
        if settings.terminalFontFamily == .sfMono {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        for name in settings.terminalFontFamily.fontNames {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func apply(theme: TerminalColorTheme, to terminalView: TerminalView) {
        terminalView.nativeForegroundColor = theme.foregroundColor
        terminalView.nativeBackgroundColor = theme.backgroundColor
        terminalView.caretColor = theme.cursorColor ?? theme.foregroundColor
        terminalView.selectedTextBackgroundColor = theme.selectionBackgroundColor ?? .selectedTextBackgroundColor
        terminalView.installColors(theme.swiftTermAnsiColors)
    }

    private static func cursorStyle(for settings: AppSettings) -> CursorStyle {
        switch (settings.terminalCursorShape, settings.terminalCursorBlinkEnabled) {
        case (.block, true):
            return .blinkBlock
        case (.block, false):
            return .steadyBlock
        case (.bar, true):
            return .blinkBar
        case (.bar, false):
            return .steadyBar
        case (.underline, true):
            return .blinkUnderline
        case (.underline, false):
            return .steadyUnderline
        }
    }
}

public enum TerminalHighlighting {
    public static let colorEnvironment: [(key: String, value: String)] = [
        ("TERM", "xterm-256color"),
        ("COLORTERM", "truecolor"),
        ("CLICOLOR", "1"),
        ("CLICOLOR_FORCE", "1"),
        ("FORCE_COLOR", "1"),
        ("SYSTEMD_COLORS", "1"),
        ("SYSTEMD_PAGERSECURE", "0"),
        ("TERM_PROGRAM", "Stacio")
    ]

    public static var remoteShellBootstrapCommand: String {
        remoteShellBootstrapCommand(level: .ansiOnly)
    }

    public static func remoteShellBootstrapCommand(level: TerminalHighlightLevelPreference) -> String {
        guard level != .off else {
            return "export TERM=xterm-256color COLORTERM=truecolor TERM_PROGRAM=Stacio"
        }
        return [
            "export TERM=xterm-256color",
            "export COLORTERM=truecolor",
            "export CLICOLOR=1",
            "export CLICOLOR_FORCE=1",
            "export FORCE_COLOR=1",
            "export SYSTEMD_COLORS=1",
            "export SYSTEMD_PAGERSECURE=0",
            "unset NO_COLOR",
            "export TERM_PROGRAM=Stacio",
            "export LESS=-R",
            "export GREP_COLOR='\(richGrepColor)'",
            "export GREP_COLORS='\(richGrepColors)'",
            "export LS_COLORS='\(richLSColors)'",
            "export LSCOLORS='\(richLSColorsBSD)'",
            "if ls --color=auto -d . >/dev/null 2>&1; then alias ls='ls --color=auto'; fi"
        ].joined(separator: "; ")
    }

    public static func shellEnvironment(
        level: TerminalHighlightLevelPreference = .ansiOnly,
        shellName: String? = nil,
        x11Display: String = ""
    ) -> [String] {
        var environment = mergedEnvironment(
            base: Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true),
            level: level
        )
        let normalizedDisplay = AppSettings.normalizedTerminalX11Display(x11Display)
        if normalizedDisplay.isEmpty == false {
            environment.removeAll { $0.hasPrefix("DISPLAY=") }
            environment.append("DISPLAY=\(normalizedDisplay)")
        }
        return TerminalCurrentDirectoryReporter.localShellEnvironment(
            base: environment,
            shellName: shellName
        )
    }

    public static func mergedEnvironment(
        base: [String],
        level: TerminalHighlightLevelPreference = .ansiOnly
    ) -> [String] {
        var values: [String: String] = [:]
        for entry in base {
            guard let (key, value) = environmentPair(entry) else { continue }
            values[key] = value
        }
        for pair in colorEnvironment where pair.key != "SYSTEMD_COLORS" && pair.key != "SYSTEMD_PAGERSECURE" {
            values[pair.key] = pair.value
        }
        guard level != .off else {
            return values
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        }
        for pair in colorEnvironment {
            values[pair.key] = pair.value
        }
        values.removeValue(forKey: "NO_COLOR")
        values["LS_COLORS"] = values["LS_COLORS"] ?? richLSColors
        values["LSCOLORS"] = values["LSCOLORS"] ?? richLSColorsBSD
        values["GREP_COLOR"] = values["GREP_COLOR"] ?? richGrepColor
        values["GREP_COLORS"] = values["GREP_COLORS"] ?? richGrepColors
        values["LESS"] = values["LESS"] ?? "-R"
        return values
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }

    public static let richGrepColor = "01;38;5;214"

    public static let richLSColorsBSD = "ExFxBxDxCxegedabagacad"

    public static let richGrepColors =
        "ms=01;38;5;214:mc=01;38;5;214:sl=:cx=:fn=38;5;75:ln=38;5;108:bn=38;5;109:se=38;5;244"

    public static let richLSColors = [
        "di=01;38;5;75",
        "ln=01;38;5;44",
        "so=01;38;5;203",
        "pi=01;38;5;179",
        "ex=01;38;5;113",
        "bd=01;38;5;221",
        "cd=01;38;5;221",
        "su=37;41",
        "sg=30;43",
        "tw=30;42",
        "ow=34;42",
        "st=37;44",
        "or=37;41",
        "mi=37;41",
        "*.swift=38;5;214",
        "*.rs=38;5;208",
        "*.go=38;5;81",
        "*.js=38;5;221",
        "*.ts=38;5;75",
        "*.tsx=38;5;75",
        "*.json=38;5;179",
        "*.yml=38;5;179",
        "*.yaml=38;5;179",
        "*.toml=38;5;179",
        "Dockerfile=38;5;75",
        "*Dockerfile=38;5;75",
        "*Dockerfile.*=38;5;75",
        "dockerfile=38;5;75",
        "*dockerfile=38;5;75",
        "*dockerfile.*=38;5;75",
        "Containerfile=38;5;75",
        "*Containerfile=38;5;75",
        "*Containerfile.*=38;5;75",
        "containerfile=38;5;75",
        "*containerfile=38;5;75",
        "*containerfile.*=38;5;75",
        ".dockerignore=38;5;244",
        "*.dockerignore=38;5;244",
        "docker-compose.yml=38;5;179",
        "*docker-compose.yml=38;5;179",
        "*docker-compose*.yml=38;5;179",
        "docker-compose.yaml=38;5;179",
        "*docker-compose.yaml=38;5;179",
        "*docker-compose*.yaml=38;5;179",
        "compose.yml=38;5;179",
        "*compose.yml=38;5;179",
        "*compose*.yml=38;5;179",
        "compose.yaml=38;5;179",
        "*compose.yaml=38;5;179",
        "*compose*.yaml=38;5;179",
        "compose.override.yml=38;5;179",
        "*compose.override*.yml=38;5;179",
        "compose.override.yaml=38;5;179",
        "*compose.override*.yaml=38;5;179",
        "compose.prod.yml=38;5;179",
        "*compose.prod*.yml=38;5;179",
        "compose.prod.yaml=38;5;179",
        "*compose.prod*.yaml=38;5;179",
        "compose.dev.yml=38;5;179",
        "*compose.dev*.yml=38;5;179",
        "compose.dev.yaml=38;5;179",
        "*compose.dev*.yaml=38;5;179",
        "compose.staging.yml=38;5;179",
        "*compose.staging*.yml=38;5;179",
        "compose.staging.yaml=38;5;179",
        "*compose.staging*.yaml=38;5;179",
        "docker-bake.hcl=38;5;179",
        "*docker-bake*.hcl=38;5;179",
        "buildkitd.toml=38;5;179",
        "daemon.json=38;5;179",
        "containers.conf=38;5;179",
        "registries.conf=38;5;179",
        "*.dockerfile=38;5;75",
        "*.containerfile=38;5;75",
        "*.oci=38;5;203",
        "Jenkinsfile=38;5;214",
        "*Jenkinsfile=38;5;214",
        "Vagrantfile=38;5;141",
        "*Vagrantfile=38;5;141",
        "*.tf=38;5;141",
        "*.tfvars=38;5;141",
        "*.env=38;5;108",
        ".env.*=38;5;108",
        ".envrc=38;5;108",
        "*.repo=38;5;179",
        "*.service=38;5;110",
        "*.timer=38;5;110",
        "*.socket=38;5;110",
        "*.mount=38;5;110",
        "*.target=38;5;110",
        "nginx.conf=38;5;110",
        "*nginx.conf=38;5;110",
        "*.nginx=38;5;110",
        "*.kubeconfig=38;5;75",
        "Chart.yaml=38;5;179",
        "*Chart.yaml=38;5;179",
        "values.yaml=38;5;179",
        "*values.yaml=38;5;179",
        "kustomization.yaml=38;5;179",
        "kustomization.yml=38;5;179",
        "sources.list=38;5;179",
        "*.sources=38;5;179",
        "*.log=38;5;244",
        "*.pem=38;5;221",
        "*.crt=38;5;221",
        "*.cer=38;5;221",
        "*.key=38;5;203",
        "*.md=38;5;183",
        "*.sh=38;5;113",
        "*.py=38;5;108",
        "*.zip=38;5;203",
        "*.tar=38;5;203",
        "*.gz=38;5;203"
    ].joined(separator: ":")

    private static func environmentPair(_ entry: String) -> (String, String)? {
        let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}
