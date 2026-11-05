import Foundation

/// 一次可执行的 V2 终端透传配置。候选路径扫描不产生该值；只有用户确认的绝对
/// executable reference 与探测证据都落盘后，配置 owner 才能发布它。
public struct LocalAgentPassthroughConfiguration: Equatable, Sendable {
    public let configurationID: String
    public let configurationRevision: Int
    public let catalogID: String
    public let catalogSetRevision: Int
    public let descriptorRevision: Int
    public let tool: LocalAgentTool
    public let displayName: String
    public let executablePath: String
    public let executableIdentityDigest: String
    public let executableReferenceConfirmedAt: Date
    public let lastVerifiedAt: Date
    public let executionProfileID: String
    public let executionProfileRevision: Int
    /// Optional structured transport selected by the verified Local Agent
    /// profile. `nil` deliberately preserves the legacy PTY compatibility
    /// path used by older records and by test/fallback resolvers.
    public let structuredProtocol: LocalAgentStructuredProtocol?
    public let authenticationState: LocalAgentAuthenticationProbeState
    public let authenticationEvidenceRevision: String
    public let cliAuthenticationScopeDigest: String
    public let cliLoginIdentityDigest: String
    public let environmentDigest: String
    public let launchArguments: [String]
    public let launchEnvironment: [String]
    public let executableName: String?
    public let pathPolicy: LocalAgentPATHPolicy
    public let customPATHEntries: [String]
    public let environmentAllowlist: [String]
    public let workingDirectoryMode: AgentProcessWorkingDirectoryMode
    public let workingDirectoryReference: String?
    public let supportLevel: CatalogSupportLevel
    public let explicitlyEnabled: Bool

    public init(
        configurationID: String,
        configurationRevision: Int,
        catalogID: String,
        catalogSetRevision: Int,
        descriptorRevision: Int,
        tool: LocalAgentTool,
        displayName: String,
        executablePath: String,
        executableIdentityDigest: String,
        executableReferenceConfirmedAt: Date,
        lastVerifiedAt: Date,
        executionProfileID: String,
        executionProfileRevision: Int,
        structuredProtocol: LocalAgentStructuredProtocol? = nil,
        authenticationState: LocalAgentAuthenticationProbeState = .unknown,
        authenticationEvidenceRevision: String,
        cliAuthenticationScopeDigest: String,
        cliLoginIdentityDigest: String,
        environmentDigest: String,
        launchArguments: [String] = [],
        launchEnvironment: [String] = [],
        executableName: String? = nil,
        pathPolicy: LocalAgentPATHPolicy = .controlled,
        customPATHEntries: [String] = [],
        environmentAllowlist: [String] = [],
        workingDirectoryMode: AgentProcessWorkingDirectoryMode = .managedWorkspace,
        workingDirectoryReference: String? = nil,
        supportLevel: CatalogSupportLevel,
        explicitlyEnabled: Bool
    ) {
        self.configurationID = configurationID
        self.configurationRevision = configurationRevision
        self.catalogID = catalogID
        self.catalogSetRevision = catalogSetRevision
        self.descriptorRevision = descriptorRevision
        self.tool = tool
        self.displayName = displayName
        self.executablePath = executablePath
        self.executableIdentityDigest = executableIdentityDigest
        self.executableReferenceConfirmedAt = executableReferenceConfirmedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.executionProfileID = executionProfileID
        self.executionProfileRevision = executionProfileRevision
        self.structuredProtocol = structuredProtocol
        self.authenticationState = authenticationState
        self.authenticationEvidenceRevision = authenticationEvidenceRevision
        self.cliAuthenticationScopeDigest = cliAuthenticationScopeDigest
        self.cliLoginIdentityDigest = cliLoginIdentityDigest
        self.environmentDigest = environmentDigest
        self.launchArguments = launchArguments
        self.launchEnvironment = launchEnvironment
        self.executableName = executableName
        self.pathPolicy = pathPolicy
        self.customPATHEntries = customPATHEntries
        self.environmentAllowlist = environmentAllowlist
        self.workingDirectoryMode = workingDirectoryMode
        self.workingDirectoryReference = workingDirectoryReference
        self.supportLevel = supportLevel
        self.explicitlyEnabled = explicitlyEnabled
    }

    public var isReadyForTerminalPassthrough: Bool {
        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicitlyEnabled
            && supportLevel != .unsupported
            && configurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && configurationRevision > 0
            && catalogID.hasPrefix("local-agent.")
            && catalogSetRevision > 0
            && descriptorRevision > 0
            && path.hasPrefix("/")
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
            && executableIdentityDigest.isEmpty == false
            && executionProfileID.isEmpty == false
            && executionProfileRevision > 0
            && authenticationState == .authenticated
            && authenticationEvidenceRevision.isEmpty == false
            && cliAuthenticationScopeDigest.isEmpty == false
            && cliLoginIdentityDigest.isEmpty == false
            && environmentDigest.isEmpty == false
            && launchEnvironment.isEmpty == false
            && LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment) == environmentDigest
            && workingDirectoryIsValid
    }

    /// Structured mode is opt-in. It shares the same verified executable,
    /// authentication, environment and working-directory contract as PTY
    /// mode, but is consumed by a protocol parser rather than a terminal view.
    public var usesStructuredRuntime: Bool {
        LocalAgentRuntimeCapabilities.supportsStructuredRuntime(
            rawIdentity: tool.catalogRawIdentity,
            structuredProtocol: structuredProtocol
        )
    }

    public var isReadyForStructuredRuntime: Bool {
        isReadyForTerminalPassthrough && usesStructuredRuntime
    }

    private var workingDirectoryIsValid: Bool {
        switch workingDirectoryMode {
        case .managedWorkspace, .askEveryTurn:
            return workingDirectoryReference == nil
        case .userSelectedLocalDirectory:
            guard let workingDirectoryReference else { return false }
            return workingDirectoryReference.hasPrefix("/")
                && URL(fileURLWithPath: workingDirectoryReference, isDirectory: true)
                    .standardizedFileURL.path == workingDirectoryReference
        }
    }
}

/// Structured local-agent support is deliberately narrower than catalog
/// discovery. Codex's app-server protocol has a bidirectional tool channel
/// that Stacio can bind to the verified terminal target. Claude's stream-json
/// print mode currently has no equivalent input/MCP result channel here, so
/// existing Claude managed-jsonl records are treated as PTY compatibility
/// records until that bridge is implemented.
public enum LocalAgentRuntimeCapabilities {
    public static func supportsStructuredRuntime(
        rawIdentity: String,
        structuredProtocol: LocalAgentStructuredProtocol?
    ) -> Bool {
        rawIdentity == LocalAgentRawIdentity.codex.rawValue && structuredProtocol == .rpc
    }

    public static func supportsManagedProfile(rawIdentity: String) -> Bool {
        rawIdentity == LocalAgentRawIdentity.codex.rawValue
    }
}

public enum LocalAgentTool: String, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case githubCopilot
    case geminiCLI
    case opencode
    case mimoCode
    case zcode
    case qwenCode

    /// Runtime adapter defaults for current official CLIs. This is not a
    /// catalog authorization and is only used when an older durable record did
    /// not persist `selectedProtocol` yet.
    public var defaultStructuredProtocol: LocalAgentStructuredProtocol? {
        switch self {
        case .codex:
            return .rpc
        case .claude:
            return .jsonl
        default:
            return nil
        }
    }

    /// Stable UI/V1 bridge only. The mapping is identity, not a source of
    /// display, executable, argv or support facts.
    public var catalogRawIdentity: String {
        switch self {
        case .codex: return LocalAgentRawIdentity.codex.rawValue
        case .claude: return LocalAgentRawIdentity.claudeCode.rawValue
        case .githubCopilot: return LocalAgentRawIdentity.githubCopilot.rawValue
        case .geminiCLI: return LocalAgentRawIdentity.geminiCli.rawValue
        case .opencode: return LocalAgentRawIdentity.opencode.rawValue
        case .mimoCode: return LocalAgentRawIdentity.mimoCode.rawValue
        case .zcode: return LocalAgentRawIdentity.zcode.rawValue
        case .qwenCode: return LocalAgentRawIdentity.qwenCode.rawValue
        }
    }

    public func descriptor(
        in catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared
    ) -> LocalAgentCatalogEntry? {
        catalog.catalogSet?.localAgent(rawIdentity: catalogRawIdentity)
    }

    public var displayName: String {
        descriptor()?.displayName ?? "Local Agent"
    }

    public var executableNames: [String] {
        descriptor()?.executableCandidates.compactMap {
            $0.kind == .pathLookup ? $0.value : nil
        } ?? []
    }

    public var embeddedTerminalArguments: [String] {
        descriptor()?.terminalPassthroughArgv ?? []
    }

    public func commonExecutablePaths(homeDirectory: String) -> [String] {
        guard let descriptor = descriptor(), descriptor.isExecutableCandidate else { return [] }
        return descriptor.executableCandidates.compactMap { candidate in
            switch candidate.kind {
            case .pathLookup:
                return nil
            case .homeRelative:
                return URL(fileURLWithPath: homeDirectory, isDirectory: true)
                    .appendingPathComponent(candidate.value)
                    .standardizedFileURL.path
            case .absolute:
                return candidate.value
            }
        }
    }
}

public protocol LocalAgentToolResolving {
    func executablePath(for tool: LocalAgentTool) -> String?
    /// V2 只接受用户确认并带完整证据的配置；PATH 探测结果默认不能升级为配置。
    func passthroughConfiguration(for tool: LocalAgentTool) -> LocalAgentPassthroughConfiguration?
    /// V1-compatible discovery used only by the Inspector's explicit
    /// compatibility entry. It is never promoted into a durable V2 Runtime.
    func legacyExecutablePath(for tool: LocalAgentTool) -> String?
}

public extension LocalAgentToolResolving {
    func passthroughConfiguration(for tool: LocalAgentTool) -> LocalAgentPassthroughConfiguration? {
        nil
    }

    func legacyExecutablePath(for tool: LocalAgentTool) -> String? {
        executablePath(for: tool)
    }
}

public struct LocalAgentToolResolver: LocalAgentToolResolving {
    private let environment: [String: String]
    private let homeDirectory: String
    private let isExecutable: (String) -> Bool
    private let isDirectory: (String) -> Bool
    private let executableDigest: (String) -> String?
    private let now: () -> Date
    private let catalog: RuntimeCatalogProviding
    private let configurationStore: LocalAgentConfigurationReading?
    /// PATH discovery is useful only while configuring a profile. Production
    /// runtime resolution must fail closed when its durable store is absent.
    private let allowsPathDiscovery: Bool
    /// Compatibility discovery is exposed only through the explicitly labelled
    /// legacy API; it cannot satisfy V2's verified configuration contract.
    private let allowsLegacyPathDiscovery: Bool

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        isDirectory: @escaping (String) -> Bool = {
            var flag: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &flag) && flag.boolValue
        },
        executableDigest: @escaping (String) -> String? = LocalAgentConfigurationIntegrity.executableDigest(path:),
        now: @escaping () -> Date = Date.init,
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared,
        configurationStore: LocalAgentConfigurationReading? = nil,
        allowsPathDiscovery: Bool = true,
        allowsLegacyPathDiscovery: Bool = false
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
        self.isDirectory = isDirectory
        self.executableDigest = executableDigest
        self.now = now
        self.catalog = catalog
        self.configurationStore = configurationStore
        self.allowsPathDiscovery = allowsPathDiscovery
        self.allowsLegacyPathDiscovery = allowsLegacyPathDiscovery
    }

    /// Production construction is explicit so PATH-discovery tests and setup
    /// screens cannot accidentally consume a user's live executable authority.
    public static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared
    ) -> Self {
        let configurationStore = LocalAgentConfigurationLiveStore.sharedIfAvailable()
        return Self(
            environment: environment,
            homeDirectory: homeDirectory,
            catalog: catalog,
            configurationStore: configurationStore,
            allowsPathDiscovery: false,
            // Compatibility is an explicit, user-selected V1 path. It must
            // remain available during upgrades and when the optional V2
            // authority sidecar cannot be opened, otherwise an installed
            // Codex/Claude becomes invisible and the pre-V2 workflow is lost.
            // This never satisfies `passthroughConfiguration(for:)` and is
            // therefore not promoted into a durable V2 Runtime.
            allowsLegacyPathDiscovery: true
        )
    }

    public func executablePath(for tool: LocalAgentTool) -> String? {
        if configurationStore != nil {
            return passthroughConfiguration(for: tool)?.executablePath
        }
        guard allowsPathDiscovery else { return nil }
        return discoveredExecutablePath(for: tool)
    }

    public func legacyExecutablePath(for tool: LocalAgentTool) -> String? {
        if let configurationStore {
            guard let records = try? configurationStore.records() else { return nil }
            let matchingRecords = records.filter { $0.rawIdentity == tool.catalogRawIdentity }
            // A record that is explicitly enabled belongs to the V2 authority
            // domain. An invalid or ambiguous enabled record must fail closed;
            // silently bypassing it through PATH would defeat the launch
            // evidence contract. Disabled/unverified migration records are
            // different: they do not grant V2 authority and may still expose
            // the explicitly labelled legacy PTY path, preserving the pre-V2
            // Inspector workflow until the user verifies the profile.
            guard matchingRecords.contains(where: \.explicitlyEnabled) == false else {
                return nil
            }
        }
        guard allowsLegacyPathDiscovery else { return nil }
        return discoveredExecutablePath(for: tool)
    }

    private func discoveredExecutablePath(for tool: LocalAgentTool) -> String? {
        guard let descriptor = tool.descriptor(in: catalog), descriptor.isExecutableCandidate else {
            return nil
        }
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { directory in
                directory.hasPrefix("/")
                    && URL(fileURLWithPath: directory).standardizedFileURL.path == directory
            }
        var seen = Set<String>()
        let candidates = descriptor.executableCandidates.flatMap { candidate -> [String] in
            switch candidate.kind {
            case .pathLookup:
                return pathDirectories.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                        .appendingPathComponent(candidate.value)
                        .standardizedFileURL.path
                }
            case .homeRelative:
                return [
                    URL(fileURLWithPath: homeDirectory, isDirectory: true)
                        .appendingPathComponent(candidate.value)
                        .standardizedFileURL.path
                ]
            case .absolute:
                return [candidate.value]
            }
        }.filter { seen.insert($0).inserted }
        return candidates.first(where: isExecutable)
    }

    public func passthroughConfiguration(for tool: LocalAgentTool) -> LocalAgentPassthroughConfiguration? {
        guard let configurationStore,
              let set = catalog.catalogSet,
              let records = try? configurationStore.records()
        else { return nil }
        let enabled = records.filter {
            $0.rawIdentity == tool.catalogRawIdentity && $0.explicitlyEnabled
        }
        // The current Composer exposes one item per stable tool identity. Until
        // it exposes configuration IDs, multiple enabled profiles are ambiguous.
        guard enabled.count == 1,
              let record = enabled.first,
              record.catalogSetRevision == set.catalogSetRevision,
              let descriptor = set.localAgent(catalogID: record.catalogID),
              descriptor.rawIdentity == record.rawIdentity,
              descriptor.revision == record.descriptorRevision,
              descriptor.isExecutableCandidate,
              descriptor.permitsPTYFallback,
              descriptor.supportedWorkingDirectoryModes.contains(record.workingDirectoryMode),
              record.authenticationState == .authenticated,
              validateExecutable(record),
              validateEvidenceDates(record),
              validateWorkingDirectory(record),
              let profile = descriptor.executionProfiles.first(where: {
                  $0.profileID == record.executionProfileID
                      && $0.revision == record.executionProfileRevision
                      && $0.supportLevel != .unsupported
              })
        else { return nil }

        let structuredProtocol: LocalAgentStructuredProtocol?
        switch profile.kind {
        case .managed:
            structuredProtocol = record.selectedProtocol ?? descriptor.structuredProtocolPriority.first
        case .terminalPassthrough, .none:
            // An explicitly persisted terminal profile remains the compatibility
            // path. Older records must not silently change transport semantics.
            structuredProtocol = nil
        }
        guard profile.kind != .managed || structuredProtocol != nil else { return nil }

        let launchEnvironment: [String]
        do {
            launchEnvironment = try LocalAgentLaunchEnvironmentBuilder.build(
                record: record,
                descriptor: descriptor,
                environment: environment,
                homeDirectory: homeDirectory
            )
        } catch {
            return nil
        }
        guard LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment) == record.environmentDigest else {
            return nil
        }
        let displayName = record.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalAgentPassthroughConfiguration(
            configurationID: record.configurationID,
            configurationRevision: Int(record.configurationRevision),
            catalogID: record.catalogID,
            catalogSetRevision: record.catalogSetRevision,
            descriptorRevision: record.descriptorRevision,
            tool: tool,
            displayName: displayName.isEmpty ? descriptor.displayName : displayName,
            executablePath: record.executablePath,
            executableIdentityDigest: record.executableIdentityDigest,
            executableReferenceConfirmedAt: record.executableReferenceConfirmedAt,
            lastVerifiedAt: record.lastVerifiedAt,
            executionProfileID: record.executionProfileID,
            executionProfileRevision: record.executionProfileRevision,
            structuredProtocol: structuredProtocol,
            authenticationState: record.authenticationState,
            authenticationEvidenceRevision: record.authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: record.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: record.cliLoginIdentityDigest,
            environmentDigest: record.environmentDigest,
            launchArguments: descriptor.terminalPassthroughArgv,
            launchEnvironment: launchEnvironment,
            executableName: URL(fileURLWithPath: record.executablePath).lastPathComponent,
            pathPolicy: record.pathPolicy,
            customPATHEntries: record.customPATHEntries,
            environmentAllowlist: record.environmentAllowlist,
            workingDirectoryMode: record.workingDirectoryMode,
            workingDirectoryReference: record.workingDirectoryReference,
            supportLevel: descriptor.supportLevel,
            explicitlyEnabled: record.explicitlyEnabled
        )
    }

    private func validateExecutable(_ record: LocalAgentConfigurationRecord) -> Bool {
        let standardized = URL(fileURLWithPath: record.executablePath).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return record.executablePath.hasPrefix("/")
            && standardized == record.executablePath
            && resolved == record.executablePath
            && isExecutable(record.executablePath)
            && executableDigest(record.executablePath) == record.executableIdentityDigest
    }

    private func validateEvidenceDates(_ record: LocalAgentConfigurationRecord) -> Bool {
        let current = now()
        return record.executableReferenceConfirmedAt <= record.lastVerifiedAt
            && record.lastVerifiedAt <= current.addingTimeInterval(300)
    }

    private func validateWorkingDirectory(_ record: LocalAgentConfigurationRecord) -> Bool {
        switch record.workingDirectoryMode {
        case .managedWorkspace, .askEveryTurn:
            return record.workingDirectoryReference == nil
        case .userSelectedLocalDirectory:
            guard let reference = record.workingDirectoryReference else { return false }
            let url = URL(fileURLWithPath: reference, isDirectory: true)
            return reference.hasPrefix("/")
                && url.standardizedFileURL.path == reference
                && url.resolvingSymlinksInPath().path == reference
                && isDirectory(reference)
        }
    }
}
