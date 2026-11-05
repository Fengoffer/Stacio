import Foundation

public enum LocalAgentRuntimeLaunchAuthorizationError: Error, Equatable {
    case unavailable
    case maintenanceBusy
    case reconciliationRequired(String)
    case configurationMutationInProgress
    case configurationChanged
}

public protocol LocalAgentRuntimeLaunchAuthorizing: AnyObject {
    func acquireUsage(
        configurationID: String,
        expectedConfigurationRevision: Int64
    ) throws -> LocalAgentRuntimeUsageLease
}

public protocol LocalAgentRuntimeConfigurationRevisionReading: AnyObject {
    func revision(configurationID: String) throws -> Int64?
}

extension LocalAgentConfigurationStore: LocalAgentRuntimeConfigurationRevisionReading {
    public func revision(configurationID: String) throws -> Int64? {
        try record(configurationID: configurationID)?.configurationRevision
    }
}

/// Runtime launch barrier shared with Settings maintenance. It occupies the
/// process-wide Settings slot only while checking the durable journal and
/// registering usage; the lease itself may coexist with other runtime leases.
public final class LocalAgentRuntimeLaunchCoordinator: LocalAgentRuntimeLaunchAuthorizing {
    private static let sharedLock = NSLock()
    private static var cachedShared: LocalAgentRuntimeLaunchCoordinator?

    private let maintenanceJournal: LocalAgentMaintenanceProcessJournalReading
    private let configurationRevisions: LocalAgentRuntimeConfigurationRevisionReading
    private let operationGate: LocalAgentSettingsOperationGate
    private let runtimeUsage: LocalAgentRuntimeUsageRegistry

    public init(
        maintenanceJournal: LocalAgentMaintenanceProcessJournalReading,
        configurationRevisions: LocalAgentRuntimeConfigurationRevisionReading,
        operationGate: LocalAgentSettingsOperationGate = .shared,
        runtimeUsage: LocalAgentRuntimeUsageRegistry = .shared
    ) {
        self.maintenanceJournal = maintenanceJournal
        self.configurationRevisions = configurationRevisions
        self.operationGate = operationGate
        self.runtimeUsage = runtimeUsage
    }

    public static func sharedIfAvailable() -> LocalAgentRuntimeLaunchCoordinator? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let cachedShared { return cachedShared }
        guard let journal = LocalAgentMaintenanceProcessJournalLiveStore.sharedIfAvailable(),
              let configurationStore = LocalAgentConfigurationLiveStore.sharedIfAvailable()
        else {
            return nil
        }
        let coordinator = LocalAgentRuntimeLaunchCoordinator(
            maintenanceJournal: journal,
            configurationRevisions: configurationStore
        )
        cachedShared = coordinator
        return coordinator
    }

    public func acquireUsage(
        configurationID: String,
        expectedConfigurationRevision: Int64
    ) throws -> LocalAgentRuntimeUsageLease {
        guard configurationID.isEmpty == false,
              expectedConfigurationRevision > 0
        else {
            throw LocalAgentRuntimeLaunchAuthorizationError.unavailable
        }
        let barrierOperationID = "local-agent-runtime-launch-\(UUID().uuidString.lowercased())"
        guard operationGate.claim(operationID: barrierOperationID) else {
            throw LocalAgentRuntimeLaunchAuthorizationError.maintenanceBusy
        }
        defer { operationGate.release(operationID: barrierOperationID) }

        let entries: [LocalAgentMaintenanceProcessJournalEntry]
        do {
            entries = try maintenanceJournal.entries()
        } catch {
            throw LocalAgentRuntimeLaunchAuthorizationError.unavailable
        }
        if let unresolved = entries.first(where: {
            LocalAgentSettingsProcessJournal.actionBlocked(
                .runtimeLaunch,
                state: $0.state,
                settlement: $0.settlement
            )
        }) {
            throw LocalAgentRuntimeLaunchAuthorizationError.reconciliationRequired(
                unresolved.referenceID
            )
        }
        if LocalAgentSettingsProcessJournal.globalLimitExceeded(
            activeProcesses: entries.map(\.state)
        ) {
            throw LocalAgentRuntimeLaunchAuthorizationError.maintenanceBusy
        }
        let currentRevision: Int64?
        do {
            currentRevision = try configurationRevisions.revision(
                configurationID: configurationID
            )
        } catch {
            throw LocalAgentRuntimeLaunchAuthorizationError.unavailable
        }
        guard currentRevision == expectedConfigurationRevision else {
            throw LocalAgentRuntimeLaunchAuthorizationError.configurationChanged
        }
        guard let lease = runtimeUsage.acquireUsage(configurationID: configurationID) else {
            throw LocalAgentRuntimeLaunchAuthorizationError.configurationMutationInProgress
        }
        return lease
    }
}
