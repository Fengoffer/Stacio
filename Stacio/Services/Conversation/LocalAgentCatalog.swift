import Foundation

/// Stable migration identities only. Product facts such as names, executables,
/// command arguments and support levels live exclusively in Runtime Catalog.
public enum LocalAgentRawIdentity: String, Codable, CaseIterable, Equatable, Sendable {
    case stacioAgent
    case codex
    case claudeCode
    case githubCopilot
    case geminiCli
    case opencode
    case mimoCode
    case zcode
    case qwenCode
    case kimiCode
}

public enum LocalAgentCatalogAction {
    public static func entries(
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared
    ) -> [LocalAgentCatalogEntry] {
        catalog.catalogSet?.localAgents ?? []
    }

    /// Migration is exact and lossless: display names, executable names and
    /// PATH candidates are never accepted as identities.
    public static func rawIdentity(from value: String) -> LocalAgentRawIdentity? {
        LocalAgentRawIdentity(rawValue: value)
    }

    public static func compatibleAgentIdentities(
        planID: String,
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared
    ) -> [String] {
        guard let set = catalog.catalogSet else { return [] }
        return set.planAgentCompatibility
            .filter {
                $0.planID == planID
                    && $0.compatible
                    && $0.supportLevel != .unsupported
                    && set.localAgent(rawIdentity: $0.agentRawIdentity)?.isExecutableCandidate == true
            }
            .map(\.agentRawIdentity)
            .sorted()
    }

    /// Account OAuth remains owned by each supported CLI. Stacio never embeds
    /// an OAuth web flow or reads the CLI's persisted account material.
    public static func embeddedOAuthForAccountSubscriptionCLI() -> Bool { false }
}
