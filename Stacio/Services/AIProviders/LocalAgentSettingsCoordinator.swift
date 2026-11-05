import Foundation

public protocol LocalAgentConfigurationDetecting: AnyObject {
    func detect(
        catalogID: String,
        userSelectedExecutablePath: String?
    ) throws -> LocalAgentDetectionReport
}

extension LocalAgentConfigurationDetector: LocalAgentConfigurationDetecting {}

public protocol LocalAgentConfigurationManaging: LocalAgentConfigurationReading {
    func record(configurationID: String) throws -> LocalAgentConfigurationRecord?

    @discardableResult
    func save(
        _ proposed: LocalAgentConfigurationRecord,
        expectedRevision: Int64?,
        operationID: String,
        eventID: String
    ) throws -> LocalAgentConfigurationRecord

    @discardableResult
    func delete(
        configurationID: String,
        expectedRevision: Int64,
        operationID: String,
        eventID: String
    ) throws -> Int64
}

extension LocalAgentConfigurationStore: LocalAgentConfigurationManaging {}

public enum LocalAgentMaintenanceAction: String, Codable, Equatable, Sendable {
    case login
    case logout
}

public struct LocalAgentMaintenanceLaunchRequest: Equatable, Sendable {
    public let operationID: String
    public let configurationID: String
    public let action: LocalAgentMaintenanceAction
    public let displayName: String
    public let executablePath: String
    public let executableIdentityDigest: String
    public let arguments: [String]
    public let environment: [String]
    public let currentDirectory: String

    public init(
        operationID: String,
        configurationID: String,
        action: LocalAgentMaintenanceAction,
        displayName: String,
        executablePath: String,
        executableIdentityDigest: String,
        arguments: [String],
        environment: [String],
        currentDirectory: String
    ) {
        self.operationID = operationID
        self.configurationID = configurationID
        self.action = action
        self.displayName = displayName
        self.executablePath = executablePath
        self.executableIdentityDigest = executableIdentityDigest
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

public enum LocalAgentMaintenanceLaunchOutcome: Equatable, Sendable {
    case exited(exitCode: Int32)
    case cancelled
    case failed(reasonCode: String)
    case stateUnknown(referenceID: String)
}

public struct LocalAgentMaintenanceProcessIdentity: Equatable, Sendable {
    public let processIdentifier: Int32
    public let processGroupIdentifier: Int32
    public let trustedStartTime: Date

    public init(
        processIdentifier: Int32,
        processGroupIdentifier: Int32,
        trustedStartTime: Date
    ) {
        self.processIdentifier = processIdentifier
        self.processGroupIdentifier = processGroupIdentifier
        self.trustedStartTime = trustedStartTime
    }
}

public protocol LocalAgentMaintenancePresenting: AnyObject {
    /// `onProcessStarted` must be called before exposing a running terminal. A
    /// false result means the durable PID/PGID record failed; the presenter must
    /// terminate the complete process group and settle as `stateUnknown`.
    func present(
        request: LocalAgentMaintenanceLaunchRequest,
        onProcessStarted: @escaping (LocalAgentMaintenanceProcessIdentity) -> Bool,
        completion: @escaping (LocalAgentMaintenanceLaunchOutcome) -> Void
    )
}

public protocol LocalAgentWebsiteOpening: AnyObject {
    func open(_ url: URL) -> Bool
}

/// Tracks only verified Local Agent configurations with a live process. It is
/// intentionally independent from TargetBinding and Agent Bridge capability
/// registries so Settings can block deletion/logout without acquiring either.
public final class LocalAgentRuntimeUsageRegistry: @unchecked Sendable {
    public static let shared = LocalAgentRuntimeUsageRegistry()

    private let lock = NSLock()
    private var tokensByConfigurationID: [String: Set<String>] = [:]
    private var mutationTokensByConfigurationID: [String: String] = [:]

    public init() {}

    @discardableResult
    public func register(configurationID: String) -> String {
        let token = UUID().uuidString.lowercased()
        lock.lock()
        tokensByConfigurationID[configurationID, default: []].insert(token)
        lock.unlock()
        return token
    }

    public func unregister(configurationID: String, token: String) {
        lock.lock()
        tokensByConfigurationID[configurationID]?.remove(token)
        if tokensByConfigurationID[configurationID]?.isEmpty == true {
            tokensByConfigurationID.removeValue(forKey: configurationID)
        }
        lock.unlock()
    }

    public func isInUse(configurationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tokensByConfigurationID[configurationID]?.isEmpty == false
    }

    public func acquireUsage(configurationID: String) -> LocalAgentRuntimeUsageLease? {
        let token = UUID().uuidString.lowercased()
        lock.lock()
        guard mutationTokensByConfigurationID[configurationID] == nil else {
            lock.unlock()
            return nil
        }
        tokensByConfigurationID[configurationID, default: []].insert(token)
        lock.unlock()
        return LocalAgentRuntimeUsageLease(
            registry: self,
            configurationID: configurationID,
            token: token
        )
    }

    public func acquireMutationFence(
        configurationID: String
    ) -> LocalAgentRuntimeMutationFence? {
        let token = UUID().uuidString.lowercased()
        lock.lock()
        guard mutationTokensByConfigurationID[configurationID] == nil,
              tokensByConfigurationID[configurationID]?.isEmpty != false
        else {
            lock.unlock()
            return nil
        }
        mutationTokensByConfigurationID[configurationID] = token
        lock.unlock()
        return LocalAgentRuntimeMutationFence(
            registry: self,
            configurationID: configurationID,
            token: token
        )
    }

    fileprivate func releaseMutationFence(configurationID: String, token: String) {
        lock.lock()
        if mutationTokensByConfigurationID[configurationID] == token {
            mutationTokensByConfigurationID.removeValue(forKey: configurationID)
        }
        lock.unlock()
    }
}

public final class LocalAgentRuntimeUsageLease: @unchecked Sendable {
    private let lock = NSLock()
    private var registry: LocalAgentRuntimeUsageRegistry?
    public let configurationID: String
    private let token: String

    fileprivate init(
        registry: LocalAgentRuntimeUsageRegistry,
        configurationID: String,
        token: String
    ) {
        self.registry = registry
        self.configurationID = configurationID
        self.token = token
    }

    public func release() {
        lock.lock()
        let registry = self.registry
        self.registry = nil
        lock.unlock()
        registry?.unregister(configurationID: configurationID, token: token)
    }

    deinit { release() }
}

public final class LocalAgentRuntimeMutationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var registry: LocalAgentRuntimeUsageRegistry?
    public let configurationID: String
    private let token: String

    fileprivate init(
        registry: LocalAgentRuntimeUsageRegistry,
        configurationID: String,
        token: String
    ) {
        self.registry = registry
        self.configurationID = configurationID
        self.token = token
    }

    public func release() {
        lock.lock()
        let registry = self.registry
        self.registry = nil
        lock.unlock()
        registry?.releaseMutationFence(configurationID: configurationID, token: token)
    }

    deinit { release() }
}

public enum LocalAgentSettingsCoordinatorError: Error, Equatable {
    case busy
    case invalidRequest(String)
    case unavailable(String)
}

/// A directory-owned official entry used by both configured and empty Local
/// Agent surfaces. The UI carries only these stable IDs; it never receives a
/// mutable or user-supplied URL.
public struct LocalAgentCodingPlanTarget: Equatable, Sendable {
    public let codingPlanCatalogID: String
    public let localAgentCatalogID: String
    public let displayName: String
    public let supportLevel: CatalogSupportLevel
    public let websiteActionID: String

    public init(
        codingPlanCatalogID: String,
        localAgentCatalogID: String,
        displayName: String,
        supportLevel: CatalogSupportLevel,
        websiteActionID: String
    ) {
        self.codingPlanCatalogID = codingPlanCatalogID
        self.localAgentCatalogID = localAgentCatalogID
        self.displayName = displayName
        self.supportLevel = supportLevel
        self.websiteActionID = websiteActionID
    }
}

/// One process-wide slot covers detection and interactive maintenance launches.
/// Separate Settings windows therefore cannot race the same CLI configuration.
public final class LocalAgentSettingsOperationGate: @unchecked Sendable {
    public static let shared = LocalAgentSettingsOperationGate()

    private let lock = NSLock()
    private var activeOperationID: String?

    public init() {}

    public func claim(operationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeOperationID == nil else { return false }
        activeOperationID = operationID
        return true
    }

    public func release(operationID: String) {
        lock.lock()
        if activeOperationID == operationID {
            activeOperationID = nil
        }
        lock.unlock()
    }

    public var hasActiveOperation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeOperationID != nil
    }
}

/// Owns one claimed process-wide operation until its business result has been
/// settled. The owner is retained by every asynchronous continuation so closing
/// Settings cannot abandon the gate. `beginSideEffects` protects maintenance
/// presenters that accidentally invoke their completion more than once.
private final class LocalAgentOperationSettlement<Result>: @unchecked Sendable {
    private enum Phase {
        case pending
        case performingSideEffects
        case finished
    }

    private let lock = NSLock()
    private let operationID: String
    private let operationGate: LocalAgentSettingsOperationGate
    private let completion: (Result) -> Void
    private var phase: Phase = .pending

    init(
        operationID: String,
        operationGate: LocalAgentSettingsOperationGate,
        completion: @escaping (Result) -> Void
    ) {
        self.operationID = operationID
        self.operationGate = operationGate
        self.completion = completion
    }

    func beginSideEffects() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .pending else { return false }
        phase = .performingSideEffects
        return true
    }

    func finish(_ result: Result) {
        lock.lock()
        guard phase != .finished else {
            lock.unlock()
            return
        }
        phase = .finished
        lock.unlock()

        operationGate.release(operationID: operationID)
        DispatchQueue.main.async { [completion] in completion(result) }
    }

    deinit {
        operationGate.release(operationID: operationID)
    }
}

public final class LocalAgentSettingsCoordinator {
    public typealias ActionCompletion = (AssistantSettingsActionExecutionResult) -> Void

    public var onConfigurationsChanged: (() -> Void)?

    private let catalog: RuntimeCatalogProviding
    private let detector: LocalAgentConfigurationDetecting
    private let store: LocalAgentConfigurationManaging
    private weak var maintenancePresenter: LocalAgentMaintenancePresenting?
    private weak var websiteOpener: LocalAgentWebsiteOpening?
    private let maintenanceJournal: LocalAgentMaintenanceProcessJournaling
    private let maintenanceEvidenceCollector: LocalAgentMaintenanceEvidenceCollecting
    private let operationGate: LocalAgentSettingsOperationGate
    private let runtimeUsage: LocalAgentRuntimeUsageRegistry
    private let environment: () -> [String: String]
    private let homeDirectory: () -> String
    private let controlState: () throws -> AgentConversationV2ControlState
    private let fileManager: FileManager
    private let now: () -> Date
    private let workerQueue: DispatchQueue

    public init(
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared,
        detector: LocalAgentConfigurationDetecting,
        store: LocalAgentConfigurationManaging,
        maintenancePresenter: LocalAgentMaintenancePresenting?,
        websiteOpener: LocalAgentWebsiteOpening?,
        maintenanceJournal: LocalAgentMaintenanceProcessJournaling,
        maintenanceEvidenceCollector: LocalAgentMaintenanceEvidenceCollecting = DarwinLocalAgentMaintenanceEvidenceCollector(),
        operationGate: LocalAgentSettingsOperationGate = .shared,
        runtimeUsage: LocalAgentRuntimeUsageRegistry = .shared,
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectory: @escaping () -> String = { NSHomeDirectory() },
        controlState: @escaping () throws -> AgentConversationV2ControlState,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        workerQueue: DispatchQueue = DispatchQueue(label: "com.stacio.local-agent.settings", qos: .userInitiated)
    ) {
        self.catalog = catalog
        self.detector = detector
        self.store = store
        self.maintenancePresenter = maintenancePresenter
        self.websiteOpener = websiteOpener
        self.maintenanceJournal = maintenanceJournal
        self.maintenanceEvidenceCollector = maintenanceEvidenceCollector
        self.operationGate = operationGate
        self.runtimeUsage = runtimeUsage
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.controlState = controlState
        self.fileManager = fileManager
        self.now = now
        self.workerQueue = workerQueue
    }

    public func catalogEntries() -> [LocalAgentCatalogEntry] {
        (catalog.catalogSet?.localAgents ?? [])
            .filter { $0.tombstone == nil && $0.supportLevel != .unsupported }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func catalogEntry(catalogID: String) -> LocalAgentCatalogEntry? {
        catalog.catalogSet?.localAgent(catalogID: catalogID)
    }

    /// Returns only account plans that have a verified, executable Local Agent
    /// compatibility mapping. Unsupported plans never reach the Settings UI.
    public func codingPlanTargets() -> [LocalAgentCodingPlanTarget] {
        guard let set = catalog.catalogSet else { return [] }
        return set.codingPlans
            .filter {
                $0.tombstone == nil
                    && $0.supportLevel != .unsupported
                    && $0.planKind == .accountSubscription
                    && $0.credentialOwner == .supportedCLI
                    && $0.authenticationKind == .cliManaged
                    && $0.modelDiscoveryStrategy == .cliManaged
                    && $0.allowedRuntimeKinds == [.localAgent]
            }
            .compactMap { plan in
                let compatibility = set.planAgentCompatibility.first {
                    $0.planID == plan.planID
                        && $0.compatible
                        && $0.supportLevel != .unsupported
                        && $0.credentialInjectionKind == .cliManagedAccount
                        && $0.allowedCapabilities.contains("terminalPassthrough")
                }
                guard let compatibility,
                      let agent = set.localAgent(rawIdentity: compatibility.agentRawIdentity),
                      agent.isExecutableCandidate,
                      agent.supportedCapabilities.contains("terminalPassthrough"),
                      agent.executionProfiles.contains(where: {
                          $0.kind == .terminalPassthrough
                              && $0.supportLevel != .unsupported
                      }),
                      let actionID = plan.quotaActionID
                        ?? set.primaryWebsiteAction(ownerCatalogID: plan.catalogID)?.actionID,
                      plan.websiteActionIDs.contains(actionID),
                      verifiedWebsiteAction(
                        in: set,
                        ownerCatalogID: plan.catalogID,
                        actionID: actionID
                      ) != nil
                else { return nil }
                return LocalAgentCodingPlanTarget(
                    codingPlanCatalogID: plan.catalogID,
                    localAgentCatalogID: agent.catalogID,
                    displayName: plan.displayName,
                    supportLevel: plan.supportLevel,
                    websiteActionID: actionID
                )
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    /// The official Coding Plan console is preferred over a generic CLI
    /// release page. A local-agent catalog action remains a strict fallback for
    /// future agents that have no compatible plan entry yet.
    public func codingPlanTarget(for record: LocalAgentConfigurationRecord) -> LocalAgentCodingPlanTarget? {
        codingPlanTargets().first {
            $0.localAgentCatalogID == record.catalogID
                || catalogEntry(catalogID: $0.localAgentCatalogID)?.rawIdentity == record.rawIdentity
        }
    }

    /// Business gate used by Settings controls. The Action Coordinator also
    /// enforces this at execution time; this method only keeps the UI honest.
    public func isLogoutAvailable() -> Bool {
        guard let state = try? controlState() else { return false }
        return LocalAgentSettingsAction.logoutAllowed(controlState: state)
    }

    public func configurations() throws -> [LocalAgentConfigurationRecord] {
        try store.records().sorted {
            if $0.userDisplayName != $1.userDisplayName {
                return $0.userDisplayName.localizedStandardCompare($1.userDisplayName) == .orderedAscending
            }
            return $0.configurationID < $1.configurationID
        }
    }

    public func maintenanceProcessEntries() throws -> [LocalAgentMaintenanceProcessJournalEntry] {
        try maintenanceJournal.entries()
    }

    /// Read-only candidate discovery. No executable reference or configuration
    /// is written until a later `localAgent.detect` Action repeats the exact path
    /// and digest after explicit user confirmation.
    public func previewDetection(
        catalogID: String,
        userSelectedExecutablePath: String? = nil,
        completion: @escaping (Result<LocalAgentDetectionReport, Error>) -> Void
    ) {
        let operationID = "local-agent-preview-\(UUID().uuidString.lowercased())"
        guard operationGate.claim(operationID: operationID) else {
            completion(.failure(LocalAgentSettingsCoordinatorError.busy))
            return
        }
        let settlement = LocalAgentOperationSettlement(
            operationID: operationID,
            operationGate: operationGate,
            completion: completion
        )
        workerQueue.async { [self, settlement] in
            let result: Result<LocalAgentDetectionReport, Error>
            do {
                try self.validateMaintenanceJournalAllowsLaunch()
                result = .success(try self.detector.detect(
                    catalogID: catalogID,
                    userSelectedExecutablePath: userSelectedExecutablePath
                ))
            } catch {
                result = .failure(error)
            }
            settlement.finish(result)
        }
    }

    public func registerOwners(
        in coordinator: AssistantSettingsActionCoordinator,
        configurationDeleteRouter: ConfigurationDeleteActionRouter
    ) throws {
        let actionIDs = [
            "localAgent.detect",
            "localAgent.changeExecutionProfile",
            "localAgent.login",
            "localAgent.logout",
            "localAgent.reconcileProcesses",
            "localAgent.openUpgrade"
        ]
        let owner: AssistantSettingsActionOwner = { [weak self] request, completion in
            guard let self else {
                completion(.failed(reasonCode: "local_agent_owner_unavailable"))
                return
            }
            switch request.actionID {
            case "localAgent.detect":
                self.performDetect(request, completion: completion)
            case "localAgent.changeExecutionProfile":
                self.performProfileChange(request, completion: completion)
            case "localAgent.login":
                self.performMaintenance(.login, request: request, completion: completion)
            case "localAgent.logout":
                self.performMaintenance(.logout, request: request, completion: completion)
            case "localAgent.reconcileProcesses":
                self.performMaintenanceReconciliation(request, completion: completion)
            case "localAgent.openUpgrade":
                self.performOpenWebsite(request, completion: completion)
            case "configuration.delete":
                self.performDelete(request, completion: completion)
            default:
                completion(.failed(reasonCode: "invalid_local_agent_action"))
            }
        }
        let deleteRegistrationID = try configurationDeleteRouter.registerOwner(
            for: .localAgent,
            owner: owner
        )
        do {
            try coordinator.registerOwner(for: actionIDs, owner: owner)
        } catch {
            configurationDeleteRouter.unregisterOwner(
                for: .localAgent,
                registrationID: deleteRegistrationID
            )
            throw error
        }
    }

    private func performDetect(
        _ request: AssistantSettingsActionRequest,
        completion: @escaping ActionCompletion
    ) {
        let input: DetectionInput
        do {
            input = try detectionInput(from: request.parameters)
        } catch {
            completion(.failed(reasonCode: "invalid_detection_request"))
            return
        }
        guard operationGate.claim(operationID: request.operationID) else {
            completion(.failed(reasonCode: "local_agent_process_busy"))
            return
        }
        guard let mutationFence = runtimeUsage.acquireMutationFence(
            configurationID: input.configurationID
        ) else {
            operationGate.release(operationID: request.operationID)
            completion(.failed(reasonCode: "local_agent_in_use"))
            return
        }
        let settlement = LocalAgentOperationSettlement(
            operationID: request.operationID,
            operationGate: operationGate,
            completion: completion
        )
        workerQueue.async { [self, settlement, mutationFence] in
            _ = mutationFence
            do {
                try self.validateMaintenanceJournalAllowsLaunch()
                let saved = try self.redetectAndSave(
                    input: input,
                    operationID: request.operationID,
                    requirePreviewDigest: true
                )
                self.publishConfigurationChange()
                settlement.finish(
                    .succeeded(proofDigest: "local-agent:\(saved.configurationID):revision:\(saved.configurationRevision)"),
                )
            } catch {
                settlement.finish(.failed(reasonCode: self.reasonCode(for: error)))
            }
        }
    }

    private func performProfileChange(
        _ request: AssistantSettingsActionRequest,
        completion: @escaping ActionCompletion
    ) {
        guard let configurationID = string("configurationID", in: request.parameters),
              let profileID = string("executionProfileID", in: request.parameters),
              let expectedRevision = int64("expectedRevision", in: request.parameters),
              validIdentifier(configurationID),
              validIdentifier(profileID)
        else {
            completion(.failed(reasonCode: "invalid_profile_request"))
            return
        }
        guard operationGate.claim(operationID: request.operationID) else {
            completion(.failed(reasonCode: "local_agent_process_busy"))
            return
        }
        guard let mutationFence = runtimeUsage.acquireMutationFence(
            configurationID: configurationID
        ) else {
            operationGate.release(operationID: request.operationID)
            completion(.failed(reasonCode: "local_agent_in_use"))
            return
        }
        let settlement = LocalAgentOperationSettlement(
            operationID: request.operationID,
            operationGate: operationGate,
            completion: completion
        )
        workerQueue.async { [self, settlement, mutationFence] in
            _ = mutationFence
            do {
                try self.validateMaintenanceJournalAllowsLaunch()
                guard let record = try self.store.record(configurationID: configurationID),
                      record.configurationRevision == expectedRevision else {
                    throw LocalAgentSettingsCoordinatorError.invalidRequest("stale_configuration")
                }
                let input = DetectionInput(
                    configurationID: record.configurationID,
                    expectedRevision: expectedRevision,
                    catalogID: record.catalogID,
                    executablePath: record.executablePath,
                    expectedExecutableDigest: record.executableIdentityDigest,
                    displayName: record.userDisplayName,
                    executionProfileID: profileID,
                    workingDirectoryMode: record.workingDirectoryMode,
                    workingDirectoryReference: record.workingDirectoryReference,
                    pathPolicy: record.pathPolicy,
                    customPATHEntries: record.customPATHEntries,
                    environmentAllowlist: record.environmentAllowlist,
                    explicitlyEnabled: record.explicitlyEnabled
                )
                let saved = try self.redetectAndSave(
                    input: input,
                    operationID: request.operationID,
                    requirePreviewDigest: false
                )
                self.publishConfigurationChange()
                settlement.finish(
                    .succeeded(proofDigest: "local-agent:\(saved.configurationID):revision:\(saved.configurationRevision)"),
                )
            } catch {
                settlement.finish(.failed(reasonCode: self.reasonCode(for: error)))
            }
        }
    }

    private func performDelete(
        _ request: AssistantSettingsActionRequest,
        completion: @escaping ActionCompletion
    ) {
        guard string("configurationKind", in: request.parameters) == ConfigurationKind.localAgent.rawValue,
              let configurationID = string("configurationID", in: request.parameters),
              let expectedRevision = int64("expectedRevision", in: request.parameters),
              validIdentifier(configurationID)
        else {
            completion(.failed(reasonCode: "invalid_local_agent_delete"))
            return
        }
        guard operationGate.claim(operationID: request.operationID) else {
            completion(.failed(reasonCode: "local_agent_process_busy"))
            return
        }
        guard let mutationFence = runtimeUsage.acquireMutationFence(
            configurationID: configurationID
        ) else {
            operationGate.release(operationID: request.operationID)
            completion(.failed(reasonCode: "local_agent_in_use"))
            return
        }
        let settlement = LocalAgentOperationSettlement(
            operationID: request.operationID,
            operationGate: operationGate,
            completion: completion
        )
        workerQueue.async { [self, settlement, mutationFence] in
            _ = mutationFence
            do {
                let revision = try self.store.delete(
                    configurationID: configurationID,
                    expectedRevision: expectedRevision,
                    operationID: request.operationID,
                    eventID: "\(request.operationID):local-agent-deleted"
                )
                self.publishConfigurationChange()
                settlement.finish(
                    .succeeded(proofDigest: "local-agent:\(configurationID):deleted-revision:\(revision)"),
                )
            } catch {
                settlement.finish(.failed(reasonCode: self.reasonCode(for: error)))
            }
        }
    }

    private func performMaintenance(
        _ action: LocalAgentMaintenanceAction,
        request: AssistantSettingsActionRequest,
        completion: @escaping ActionCompletion
    ) {
        guard let configurationID = string("configurationID", in: request.parameters),
              let expectedRevision = int64("expectedRevision", in: request.parameters),
              validIdentifier(configurationID)
        else {
            completion(.failed(reasonCode: "invalid_maintenance_request"))
            return
        }
        if action == .logout {
            do {
                guard LocalAgentSettingsAction.logoutAllowed(controlState: try controlState()) else {
                    completion(.failed(reasonCode: "logout_requires_draining_or_disabled"))
                    return
                }
            } catch {
                completion(.failed(reasonCode: "control_state_unavailable"))
                return
            }
        }
        guard operationGate.claim(operationID: request.operationID) else {
            completion(.failed(reasonCode: "local_agent_process_busy"))
            return
        }
        guard let mutationFence = runtimeUsage.acquireMutationFence(
            configurationID: configurationID
        ) else {
            operationGate.release(operationID: request.operationID)
            completion(.failed(reasonCode: "local_agent_in_use"))
            return
        }

        let settlement = LocalAgentOperationSettlement(
            operationID: request.operationID,
            operationGate: operationGate,
            completion: completion
        )

        workerQueue.async { [self, settlement, mutationFence] in
            do {
                guard let record = try self.store.record(configurationID: configurationID),
                      record.configurationRevision == expectedRevision else {
                    throw LocalAgentSettingsCoordinatorError.invalidRequest("stale_configuration")
                }
                let launch = try self.maintenanceRequest(
                    action: action,
                    operationID: request.operationID,
                    record: record
                )
                try self.validateMaintenanceJournalAllowsLaunch()
                let journalEntry = try self.maintenanceJournal.prepare(
                    referenceID: request.operationID,
                    operationID: request.operationID,
                    configurationID: record.configurationID,
                    action: action,
                    executablePath: record.executablePath,
                    executableIdentityDigest: record.executableIdentityDigest,
                    environmentDigest: record.environmentDigest,
                    processGeneration: nil
                )
                _ = try self.maintenanceJournal.transition(
                    referenceID: journalEntry.referenceID,
                    event: .beginStart,
                    processIdentifier: nil,
                    processGroupIdentifier: nil,
                    exitCode: nil,
                    failureReason: nil
                )
                DispatchQueue.main.async { [self, settlement, mutationFence] in
                    guard let presenter = self.maintenancePresenter else {
                        _ = try? self.maintenanceJournal.transition(
                            referenceID: journalEntry.referenceID,
                            event: .startFailed,
                            processIdentifier: nil,
                            processGroupIdentifier: nil,
                            exitCode: nil,
                            failureReason: "maintenance_terminal_unavailable"
                        )
                        settlement.finish(.failed(reasonCode: "maintenance_terminal_unavailable"))
                        return
                    }
                    presenter.present(
                        request: launch,
                        onProcessStarted: { [maintenanceJournal] identity in
                            do {
                                _ = try maintenanceJournal.transition(
                                    referenceID: journalEntry.referenceID,
                                    event: .processStarted,
                                    processIdentifier: identity.processIdentifier,
                                    processGroupIdentifier: identity.processGroupIdentifier,
                                    trustedProcessStartTime: identity.trustedStartTime,
                                    exitCode: nil,
                                    failureReason: nil
                                )
                                return true
                            } catch {
                                _ = try? maintenanceJournal.transition(
                                    referenceID: journalEntry.referenceID,
                                    event: .settlementUnknown,
                                    processIdentifier: identity.processIdentifier,
                                    processGroupIdentifier: identity.processGroupIdentifier,
                                    trustedProcessStartTime: identity.trustedStartTime,
                                    exitCode: nil,
                                    failureReason: "process_identity_persistence_failed"
                                )
                                return false
                            }
                        },
                        completion: { [self, settlement, mutationFence] outcome in
                            guard settlement.beginSideEffects() else { return }
                            self.settleMaintenance(
                                action: action,
                                request: request,
                                originalRecord: record,
                                journalReferenceID: journalEntry.referenceID,
                                outcome: outcome,
                                mutationFence: mutationFence,
                                settlement: settlement
                            )
                        }
                    )
                }
            } catch {
                settlement.finish(.failed(reasonCode: self.reasonCode(for: error)))
            }
        }
    }

    private func settleMaintenance(
        action: LocalAgentMaintenanceAction,
        request: AssistantSettingsActionRequest,
        originalRecord: LocalAgentConfigurationRecord,
        journalReferenceID: String,
        outcome: LocalAgentMaintenanceLaunchOutcome,
        mutationFence: LocalAgentRuntimeMutationFence,
        settlement: LocalAgentOperationSettlement<AssistantSettingsActionExecutionResult>
    ) {
        switch outcome {
        case .cancelled:
            finishMaintenanceJournal(
                referenceID: journalReferenceID,
                preferredEvent: .treeExitedCancelled,
                fallbackEvent: .cancel,
                exitCode: nil,
                failureReason: nil,
                successResult: .cancelled,
                settlement: settlement
            )
        case .failed(let reasonCode):
            finishMaintenanceJournal(
                referenceID: journalReferenceID,
                preferredEvent: .treeExitedFailed,
                fallbackEvent: .startFailed,
                exitCode: nil,
                failureReason: reasonCode,
                successResult: .failed(reasonCode: reasonCode),
                settlement: settlement
            )
        case .stateUnknown:
            do {
                _ = try maintenanceJournal.transition(
                    referenceID: journalReferenceID,
                    event: .settlementUnknown,
                    processIdentifier: nil,
                    processGroupIdentifier: nil,
                    exitCode: nil,
                    failureReason: "process_settlement_unknown"
                )
            } catch {
                // The existing nonterminal record is itself reconciliation evidence.
            }
            settlement.finish(.reconciliationRequired(referenceID: journalReferenceID))
        case .exited(let exitCode):
            guard exitCode == 0 else {
                let reasonCode = "maintenance_exit_\(exitCode)"
                finishMaintenanceJournal(
                    referenceID: journalReferenceID,
                    preferredEvent: .treeExitedFailed,
                    fallbackEvent: .startFailed,
                    exitCode: exitCode,
                    failureReason: reasonCode,
                    successResult: .failed(reasonCode: reasonCode),
                    settlement: settlement
                )
                return
            }
            workerQueue.async { [self, settlement, mutationFence] in
                _ = mutationFence
                do {
                    let refreshed = try self.refreshAuthenticationEvidence(
                        record: originalRecord,
                        operationID: request.operationID
                    )
                    self.publishConfigurationChange()
                    let verified: Bool
                    switch action {
                    case .login:
                        verified = refreshed.authenticationState == .authenticated
                    case .logout:
                        verified = refreshed.authenticationState == .needsLogin
                    }
                    if verified {
                        do {
                            _ = try self.maintenanceJournal.transition(
                                referenceID: journalReferenceID,
                                event: .treeExited(businessResultCommitted: true),
                                processIdentifier: nil,
                                processGroupIdentifier: nil,
                                exitCode: exitCode,
                                failureReason: nil
                            )
                            settlement.finish(
                                .succeeded(proofDigest: "local-agent:\(refreshed.configurationID):auth-revision:\(refreshed.configurationRevision)")
                            )
                        } catch {
                            settlement.finish(.reconciliationRequired(referenceID: journalReferenceID))
                        }
                    } else if refreshed.authenticationState == .unknown {
                        self.requireMaintenanceReconciliation(
                            referenceID: journalReferenceID,
                            exitCode: exitCode,
                            settlement: settlement
                        )
                    } else {
                        self.finishMaintenanceJournal(
                            referenceID: journalReferenceID,
                            preferredEvent: .treeExitedFailed,
                            fallbackEvent: .startFailed,
                            exitCode: exitCode,
                            failureReason: "authentication_state_not_changed",
                            successResult: .failed(reasonCode: "authentication_state_not_changed"),
                            settlement: settlement
                        )
                    }
                } catch {
                    self.requireMaintenanceReconciliation(
                        referenceID: journalReferenceID,
                        exitCode: exitCode,
                        settlement: settlement
                    )
                }
            }
        }
    }

    private func validateMaintenanceJournalAllowsLaunch() throws {
        let entries = try maintenanceJournal.entries()
        if entries.contains(where: {
            LocalAgentSettingsProcessJournal.reconciliationRequired(
                state: $0.state,
                settlement: $0.settlement
            )
        }) {
            throw LocalAgentSettingsCoordinatorError.unavailable("local_agent_reconciliation_required")
        }
        if LocalAgentSettingsProcessJournal.globalLimitExceeded(
            activeProcesses: entries.map(\.state)
        ) {
            throw LocalAgentSettingsCoordinatorError.busy
        }
    }

    private func finishMaintenanceJournal(
        referenceID: String,
        preferredEvent: LocalAgentSettingsProcessEvent,
        fallbackEvent: LocalAgentSettingsProcessEvent,
        exitCode: Int32?,
        failureReason: String?,
        successResult: AssistantSettingsActionExecutionResult,
        settlement: LocalAgentOperationSettlement<AssistantSettingsActionExecutionResult>
    ) {
        do {
            do {
                _ = try maintenanceJournal.transition(
                    referenceID: referenceID,
                    event: preferredEvent,
                    processIdentifier: nil,
                    processGroupIdentifier: nil,
                    exitCode: exitCode,
                    failureReason: failureReason
                )
            } catch LocalAgentMaintenanceProcessJournalStoreError.invalidTransition {
                _ = try maintenanceJournal.transition(
                    referenceID: referenceID,
                    event: fallbackEvent,
                    processIdentifier: nil,
                    processGroupIdentifier: nil,
                    exitCode: exitCode,
                    failureReason: failureReason
                )
            }
            settlement.finish(successResult)
        } catch {
            settlement.finish(.reconciliationRequired(referenceID: referenceID))
        }
    }

    private func requireMaintenanceReconciliation(
        referenceID: String,
        exitCode: Int32?,
        settlement: LocalAgentOperationSettlement<AssistantSettingsActionExecutionResult>
    ) {
        do {
            _ = try maintenanceJournal.transition(
                referenceID: referenceID,
                event: .treeExited(businessResultCommitted: false),
                processIdentifier: nil,
                processGroupIdentifier: nil,
                exitCode: exitCode,
                failureReason: "authentication_reprobe_unresolved"
            )
        } catch {
            // Keeping the existing nonterminal journal is fail closed.
        }
        settlement.finish(.reconciliationRequired(referenceID: referenceID))
    }

    private func performOpenWebsite(
        _ request: AssistantSettingsActionRequest,
        completion: @escaping ActionCompletion
    ) {
        guard let set = catalog.catalogSet else {
            completion(.failed(reasonCode: "website_configuration_unavailable"))
            return
        }

        let suppliedConfigurationID = string("configurationID", in: request.parameters)
        let suppliedCatalogID = string("catalogID", in: request.parameters)
        let suppliedActionID = string("websiteActionID", in: request.parameters)
        var ownerCatalogID: String?
        var defaultActionID: String?

        if let suppliedConfigurationID {
            guard validIdentifier(suppliedConfigurationID),
                  let record = try? store.record(configurationID: suppliedConfigurationID)
            else {
                completion(.failed(reasonCode: "website_configuration_unavailable"))
                return
            }
            if let target = codingPlanTarget(for: record) {
                ownerCatalogID = target.codingPlanCatalogID
                defaultActionID = target.websiteActionID
                if let suppliedCatalogID,
                   suppliedCatalogID != target.codingPlanCatalogID
                {
                    completion(.failed(reasonCode: "website_configuration_mismatch"))
                    return
                }
            } else if let descriptor = set.localAgent(catalogID: record.catalogID) {
                ownerCatalogID = descriptor.catalogID
                defaultActionID = descriptor.upgradeActionID
                if let suppliedCatalogID, suppliedCatalogID != descriptor.catalogID {
                    completion(.failed(reasonCode: "website_configuration_mismatch"))
                    return
                }
            }
        } else if let suppliedCatalogID, validIdentifier(suppliedCatalogID) {
            if let planTarget = codingPlanTargets().first(where: {
                $0.codingPlanCatalogID == suppliedCatalogID
            }), let plan = set.codingPlan(catalogID: planTarget.codingPlanCatalogID) {
                ownerCatalogID = plan.catalogID
                defaultActionID = planTarget.websiteActionID
            } else if let descriptor = set.localAgent(catalogID: suppliedCatalogID) {
                ownerCatalogID = descriptor.catalogID
                defaultActionID = descriptor.upgradeActionID
            }
        }

        guard let ownerCatalogID,
              let requestedActionID = suppliedActionID ?? defaultActionID,
              let entry = verifiedWebsiteAction(
                  in: set,
                  ownerCatalogID: ownerCatalogID,
                  actionID: requestedActionID
              ),
              let website = entry.descriptor,
              website.url.scheme?.lowercased() == "https",
              let websiteOpener,
              websiteOpener.open(website.url)
        else {
            completion(.failed(reasonCode: "verified_website_action_unavailable"))
            return
        }
        completion(.succeeded(proofDigest: "website-action:\(entry.actionID)"))
    }

    private func verifiedWebsiteAction(
        in set: RuntimeCatalogSet,
        ownerCatalogID: String,
        actionID: String
    ) -> WebsiteActionEntry? {
        guard validIdentifier(ownerCatalogID), validIdentifier(actionID),
              let ownerIsDeclared = set.codingPlan(catalogID: ownerCatalogID)
                .map({ $0.websiteActionIDs.contains(actionID) })
                ?? set.localAgent(catalogID: ownerCatalogID)
                    .map({ $0.websiteActionIDs.contains(actionID) }),
              ownerIsDeclared
        else { return nil }
        return set.websiteActions.first {
            $0.actionID == actionID
                && $0.ownerCatalogID == ownerCatalogID
                && $0.source == .catalog
                && $0.verifiedAt != nil
                && !$0.isPromotional
                && $0.supportLevel != .unsupported
        }
    }

    private func performMaintenanceReconciliation(
        _ request: AssistantSettingsActionRequest,
        completion: @escaping ActionCompletion
    ) {
        let requestedReferenceID = string("referenceID", in: request.parameters)
        if let requestedReferenceID, validIdentifier(requestedReferenceID) == false {
            completion(.failed(reasonCode: "invalid_reconciliation_request"))
            return
        }
        guard operationGate.claim(operationID: request.operationID) else {
            completion(.failed(reasonCode: "local_agent_process_busy"))
            return
        }
        let settlement = LocalAgentOperationSettlement(
            operationID: request.operationID,
            operationGate: operationGate,
            completion: completion
        )
        workerQueue.async { [self, settlement] in
            do {
                let entries = try self.maintenanceJournal.entries()
                let candidates = entries.filter {
                    LocalAgentSettingsProcessJournal.reconciliationRequired(
                        state: $0.state,
                        settlement: $0.settlement
                    )
                }
                let entry: LocalAgentMaintenanceProcessJournalEntry
                if let requestedReferenceID {
                    guard let match = entries.first(where: { $0.referenceID == requestedReferenceID }) else {
                        settlement.finish(.failed(reasonCode: "maintenance_reconciliation_not_found"))
                        return
                    }
                    if match.state.isTerminal {
                        settlement.finish(
                            .succeeded(proofDigest: "local-agent-maintenance:\(match.referenceID):\(match.state)")
                        )
                        return
                    }
                    guard candidates.contains(where: { $0.referenceID == match.referenceID }) else {
                        settlement.finish(.failed(reasonCode: "maintenance_reconciliation_not_required"))
                        return
                    }
                    entry = match
                } else {
                    guard candidates.count == 1, let only = candidates.first else {
                        let reason = candidates.isEmpty
                            ? "maintenance_reconciliation_not_required"
                            : "maintenance_reconciliation_reference_required"
                        settlement.finish(.failed(reasonCode: reason))
                        return
                    }
                    entry = only
                }

                let evidence = try self.maintenanceEvidenceCollector.collectEvidence(for: entry)
                do {
                    let reconciled = try self.maintenanceJournal.reconcile(
                        referenceID: entry.referenceID,
                        evidence: evidence
                    )
                    self.publishConfigurationChange()
                    settlement.finish(
                        .succeeded(
                            proofDigest: "local-agent-maintenance:\(reconciled.referenceID):\(reconciled.state)"
                        )
                    )
                } catch LocalAgentMaintenanceProcessJournalStoreError.insufficientReconciliationEvidence {
                    settlement.finish(.reconciliationRequired(referenceID: entry.referenceID))
                }
            } catch {
                if let referenceID = requestedReferenceID {
                    settlement.finish(.reconciliationRequired(referenceID: referenceID))
                } else {
                    settlement.finish(.failed(reasonCode: self.reasonCode(for: error)))
                }
            }
        }
    }

    private func redetectAndSave(
        input: DetectionInput,
        operationID: String,
        requirePreviewDigest: Bool
    ) throws -> LocalAgentConfigurationRecord {
        if let existing = try store.record(configurationID: input.configurationID) {
            guard input.expectedRevision == existing.configurationRevision,
                  existing.catalogID == input.catalogID else {
                throw LocalAgentSettingsCoordinatorError.invalidRequest("stale_configuration")
            }
        } else if input.expectedRevision != nil {
            throw LocalAgentSettingsCoordinatorError.invalidRequest("missing_configuration")
        }
        let report = try detector.detect(
            catalogID: input.catalogID,
            userSelectedExecutablePath: input.executablePath
        )
        guard let detected = report.candidates.first(where: {
            $0.executablePath == input.executablePath
                && $0.executableIdentityDigest == input.expectedExecutableDigest
        }) else {
            throw LocalAgentSettingsCoordinatorError.unavailable("confirmed_candidate_changed")
        }
        if requirePreviewDigest {
            guard LocalAgentConfigurationIntegrity.isSHA256Digest(input.expectedExecutableDigest) else {
                throw LocalAgentSettingsCoordinatorError.invalidRequest("missing_confirmation_digest")
            }
        }
        try validateWorkingDirectory(input)
        let draft = LocalAgentConfigurationDraft(
            configurationID: input.configurationID,
            displayName: input.displayName,
            detectedExecutable: detected,
            executionProfileID: input.executionProfileID,
            workingDirectoryMode: input.workingDirectoryMode,
            workingDirectoryReference: input.workingDirectoryReference,
            pathPolicy: input.pathPolicy,
            customPATHEntries: input.customPATHEntries,
            environmentAllowlist: input.environmentAllowlist,
            explicitlyEnabled: input.explicitlyEnabled
        )
        let proposed = try LocalAgentConfigurationProposalFactory.makeRecord(
            from: draft,
            catalog: catalog,
            environment: environment(),
            homeDirectory: homeDirectory(),
            confirmedAt: now()
        )
        return try store.save(
            proposed,
            expectedRevision: input.expectedRevision,
            operationID: operationID,
            eventID: "\(operationID):local-agent-verified"
        )
    }

    private func refreshAuthenticationEvidence(
        record: LocalAgentConfigurationRecord,
        operationID: String
    ) throws -> LocalAgentConfigurationRecord {
        let report = try detector.detect(
            catalogID: record.catalogID,
            userSelectedExecutablePath: record.executablePath
        )
        guard let detected = report.candidates.first(where: {
            $0.executablePath == record.executablePath
                && $0.executableIdentityDigest == record.executableIdentityDigest
        }) else {
            throw LocalAgentSettingsCoordinatorError.unavailable("authentication_reprobe_failed")
        }
        let draft = LocalAgentConfigurationDraft(
            configurationID: record.configurationID,
            displayName: record.userDisplayName,
            detectedExecutable: detected,
            executionProfileID: record.executionProfileID,
            workingDirectoryMode: record.workingDirectoryMode,
            workingDirectoryReference: record.workingDirectoryReference,
            pathPolicy: record.pathPolicy,
            customPATHEntries: record.customPATHEntries,
            environmentAllowlist: record.environmentAllowlist,
            explicitlyEnabled: record.explicitlyEnabled
        )
        let proposed = try LocalAgentConfigurationProposalFactory.makeRecord(
            from: draft,
            catalog: catalog,
            environment: environment(),
            homeDirectory: homeDirectory(),
            confirmedAt: now()
        )
        return try store.save(
            proposed,
            expectedRevision: record.configurationRevision,
            operationID: operationID,
            eventID: "\(operationID):local-agent-auth-refreshed"
        )
    }

    private func maintenanceRequest(
        action: LocalAgentMaintenanceAction,
        operationID: String,
        record: LocalAgentConfigurationRecord
    ) throws -> LocalAgentMaintenanceLaunchRequest {
        guard let set = catalog.catalogSet,
              set.catalogSetRevision == record.catalogSetRevision,
              let descriptor = set.localAgent(catalogID: record.catalogID),
              descriptor.revision == record.descriptorRevision,
              descriptor.rawIdentity == record.rawIdentity,
              URL(fileURLWithPath: record.executablePath).resolvingSymlinksInPath().path == record.executablePath,
              fileManager.isExecutableFile(atPath: record.executablePath),
              LocalAgentConfigurationIntegrity.executableDigest(path: record.executablePath)
                == record.executableIdentityDigest
        else {
            throw LocalAgentSettingsCoordinatorError.unavailable("maintenance_evidence_changed")
        }
        let arguments: [String]
        switch action {
        case .login:
            guard let loginArgv = descriptor.loginArgv else {
                throw LocalAgentSettingsCoordinatorError.unavailable("login_not_supported")
            }
            arguments = loginArgv
        case .logout:
            guard let logoutArgv = descriptor.logoutArgv else {
                throw LocalAgentSettingsCoordinatorError.unavailable("logout_not_supported")
            }
            arguments = logoutArgv
        }
        let launchEnvironment = try LocalAgentLaunchEnvironmentBuilder.build(
            record: record,
            descriptor: descriptor,
            environment: environment(),
            homeDirectory: homeDirectory()
        )
        guard LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment) == record.environmentDigest else {
            throw LocalAgentSettingsCoordinatorError.unavailable("maintenance_environment_changed")
        }
        return LocalAgentMaintenanceLaunchRequest(
            operationID: operationID,
            configurationID: record.configurationID,
            action: action,
            displayName: record.userDisplayName.isEmpty ? descriptor.displayName : record.userDisplayName,
            executablePath: record.executablePath,
            executableIdentityDigest: record.executableIdentityDigest,
            arguments: arguments,
            environment: launchEnvironment,
            currentDirectory: homeDirectory()
        )
    }

    private func detectionInput(from parameters: [String: SettingValue]) throws -> DetectionInput {
        guard let configurationID = string("configurationID", in: parameters),
              let catalogID = string("catalogID", in: parameters),
              let executablePath = string("executablePath", in: parameters),
              let expectedDigest = string("executableIdentityDigest", in: parameters),
              let displayName = string("displayName", in: parameters),
              let profileID = string("executionProfileID", in: parameters),
              let workingDirectoryRaw = string("workingDirectoryMode", in: parameters),
              let workingDirectoryMode = AgentProcessWorkingDirectoryMode(rawValue: workingDirectoryRaw),
              let pathPolicyRaw = string("pathPolicy", in: parameters),
              let pathPolicy = LocalAgentPATHPolicy(rawValue: pathPolicyRaw),
              let explicitlyEnabled = bool("explicitlyEnabled", in: parameters),
              validIdentifier(configurationID),
              validIdentifier(catalogID),
              validIdentifier(profileID),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.count <= 128,
              executablePath.hasPrefix("/"),
              URL(fileURLWithPath: executablePath).standardizedFileURL.path == executablePath,
              LocalAgentConfigurationIntegrity.isSHA256Digest(expectedDigest)
        else {
            throw LocalAgentSettingsCoordinatorError.invalidRequest("detection_parameters")
        }
        return DetectionInput(
            configurationID: configurationID,
            expectedRevision: int64("expectedRevision", in: parameters),
            catalogID: catalogID,
            executablePath: executablePath,
            expectedExecutableDigest: expectedDigest,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            executionProfileID: profileID,
            workingDirectoryMode: workingDirectoryMode,
            workingDirectoryReference: optionalString("workingDirectoryReference", in: parameters),
            pathPolicy: pathPolicy,
            customPATHEntries: stringArray("customPATHEntries", in: parameters),
            environmentAllowlist: stringArray("environmentAllowlist", in: parameters),
            explicitlyEnabled: explicitlyEnabled
        )
    }

    private func validateWorkingDirectory(_ input: DetectionInput) throws {
        switch input.workingDirectoryMode {
        case .managedWorkspace:
            guard input.workingDirectoryReference == nil else {
                throw LocalAgentSettingsCoordinatorError.invalidRequest("managed_workspace_reference")
            }
        case .askEveryTurn:
            guard input.workingDirectoryReference == nil else {
                throw LocalAgentSettingsCoordinatorError.invalidRequest("ask_every_turn_reference")
            }
        case .userSelectedLocalDirectory:
            guard let path = input.workingDirectoryReference,
                  path.hasPrefix("/"),
                  URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path,
                  URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path == path
            else {
                throw LocalAgentSettingsCoordinatorError.invalidRequest("working_directory")
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LocalAgentSettingsCoordinatorError.unavailable("working_directory_missing")
            }
        }
    }

    private func reasonCode(for error: Error) -> String {
        switch error {
        case LocalAgentSettingsCoordinatorError.busy:
            return "local_agent_process_busy"
        case LocalAgentSettingsCoordinatorError.invalidRequest(let value):
            return value
        case LocalAgentSettingsCoordinatorError.unavailable(let value):
            return value
        case LocalAgentConfigurationStoreError.staleRevision:
            return "stale_configuration"
        case LocalAgentConfigurationDetectionError.executableChanged:
            return "executable_changed"
        case LocalAgentConfigurationDetectionError.invalidExecutableReference:
            return "invalid_executable_reference"
        default:
            return "local_agent_operation_failed"
        }
    }

    private func publishConfigurationChange() {
        DispatchQueue.main.async { [weak self] in self?.onConfigurationsChanged?() }
    }

    private func complete(
        _ result: AssistantSettingsActionExecutionResult,
        completion: @escaping ActionCompletion
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private func string(_ key: String, in parameters: [String: SettingValue]) -> String? {
        guard case .string(let value) = parameters[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalString(_ key: String, in parameters: [String: SettingValue]) -> String? {
        guard case .string(let value) = parameters[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func int64(_ key: String, in parameters: [String: SettingValue]) -> Int64? {
        guard case .int(let value) = parameters[key], value >= 0 else { return nil }
        return Int64(value)
    }

    private func bool(_ key: String, in parameters: [String: SettingValue]) -> Bool? {
        guard case .bool(let value) = parameters[key] else { return nil }
        return value
    }

    private func stringArray(_ key: String, in parameters: [String: SettingValue]) -> [String] {
        guard case .stringArray(let values) = parameters[key] else { return [] }
        return values
    }

    private func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 160 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }
    }
}

private struct DetectionInput {
    let configurationID: String
    let expectedRevision: Int64?
    let catalogID: String
    let executablePath: String
    let expectedExecutableDigest: String
    let displayName: String
    let executionProfileID: String
    let workingDirectoryMode: AgentProcessWorkingDirectoryMode
    let workingDirectoryReference: String?
    let pathPolicy: LocalAgentPATHPolicy
    let customPATHEntries: [String]
    let environmentAllowlist: [String]
    let explicitlyEnabled: Bool
}
