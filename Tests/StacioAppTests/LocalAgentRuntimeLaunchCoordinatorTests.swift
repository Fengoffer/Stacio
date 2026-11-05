import Foundation
import XCTest
@testable import StacioApp

final class LocalAgentRuntimeLaunchCoordinatorTests: XCTestCase {
    func testCleanJournalGrantsLeaseUntilExplicitRelease() throws {
        let usage = LocalAgentRuntimeUsageRegistry()
        let coordinator = makeCoordinator(entries: [], usage: usage)

        let lease = try coordinator.acquireUsage(
            configurationID: "local-agent-codex",
            expectedConfigurationRevision: 1
        )

        XCTAssertTrue(usage.isInUse(configurationID: "local-agent-codex"))
        lease.release()
        XCTAssertFalse(usage.isInUse(configurationID: "local-agent-codex"))
    }

    func testEmptyConfigurationIDFailsClosed() {
        let usage = LocalAgentRuntimeUsageRegistry()
        let coordinator = makeCoordinator(entries: [], usage: usage)

        XCTAssertThrowsError(try coordinator.acquireUsage(
            configurationID: "",
            expectedConfigurationRevision: 1
        )) { error in
            XCTAssertEqual(error as? LocalAgentRuntimeLaunchAuthorizationError, .unavailable)
        }
        XCTAssertFalse(usage.isInUse(configurationID: ""))
    }

    func testStateUnknownBlocksWithDurableReference() {
        let usage = LocalAgentRuntimeUsageRegistry()
        let coordinator = makeCoordinator(
            entries: [entry(referenceID: "maintenance-needs-reconcile", state: .stateUnknown, settlement: .unknown)],
            usage: usage
        )

        XCTAssertThrowsError(
            try coordinator.acquireUsage(
                configurationID: "local-agent-codex",
                expectedConfigurationRevision: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAgentRuntimeLaunchAuthorizationError,
                .reconciliationRequired("maintenance-needs-reconcile")
            )
        }
        XCTAssertFalse(usage.isInUse(configurationID: "local-agent-codex"))
    }

    func testNonterminalMaintenanceBlocksRuntimeLaunch() {
        let usage = LocalAgentRuntimeUsageRegistry()
        let coordinator = makeCoordinator(
            entries: [entry(referenceID: "maintenance-running", state: .running, settlement: .pending)],
            usage: usage
        )

        XCTAssertThrowsError(
            try coordinator.acquireUsage(
                configurationID: "local-agent-codex",
                expectedConfigurationRevision: 1
            )
        ) { error in
            XCTAssertEqual(error as? LocalAgentRuntimeLaunchAuthorizationError, .maintenanceBusy)
        }
        XCTAssertFalse(usage.isInUse(configurationID: "local-agent-codex"))
    }

    func testJournalReadFailureFailsClosedAndReleasesOperationGate() {
        let gate = LocalAgentSettingsOperationGate()
        let usage = LocalAgentRuntimeUsageRegistry()
        let coordinator = LocalAgentRuntimeLaunchCoordinator(
            maintenanceJournal: ThrowingRuntimeJournal(),
            configurationRevisions: StaticRuntimeConfigurationRevisions(),
            operationGate: gate,
            runtimeUsage: usage
        )

        XCTAssertThrowsError(
            try coordinator.acquireUsage(
                configurationID: "local-agent-codex",
                expectedConfigurationRevision: 1
            )
        ) { error in
            XCTAssertEqual(error as? LocalAgentRuntimeLaunchAuthorizationError, .unavailable)
        }
        XCTAssertFalse(gate.hasActiveOperation)
        XCTAssertFalse(usage.isInUse(configurationID: "local-agent-codex"))
    }

    func testSettingsOperationGateBlocksRuntimeLaunch() {
        let gate = LocalAgentSettingsOperationGate()
        let usage = LocalAgentRuntimeUsageRegistry()
        XCTAssertTrue(gate.claim(operationID: "settings-maintenance"))
        defer { gate.release(operationID: "settings-maintenance") }
        let coordinator = makeCoordinator(entries: [], gate: gate, usage: usage)

        XCTAssertThrowsError(
            try coordinator.acquireUsage(
                configurationID: "local-agent-codex",
                expectedConfigurationRevision: 1
            )
        ) { error in
            XCTAssertEqual(error as? LocalAgentRuntimeLaunchAuthorizationError, .maintenanceBusy)
        }
        XCTAssertFalse(usage.isInUse(configurationID: "local-agent-codex"))
    }

    func testConfigurationMutationFenceBlocksRuntimeLaunch() throws {
        let gate = LocalAgentSettingsOperationGate()
        let usage = LocalAgentRuntimeUsageRegistry()
        let fence = try XCTUnwrap(
            usage.acquireMutationFence(configurationID: "local-agent-codex")
        )
        let coordinator = makeCoordinator(entries: [], gate: gate, usage: usage)

        XCTAssertThrowsError(
            try coordinator.acquireUsage(
                configurationID: "local-agent-codex",
                expectedConfigurationRevision: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAgentRuntimeLaunchAuthorizationError,
                .configurationMutationInProgress
            )
        }
        XCTAssertFalse(gate.hasActiveOperation)
        XCTAssertFalse(usage.isInUse(configurationID: "local-agent-codex"))

        fence.release()
        let lease = try coordinator.acquireUsage(
            configurationID: "local-agent-codex",
            expectedConfigurationRevision: 1
        )
        XCTAssertTrue(usage.isInUse(configurationID: "local-agent-codex"))
        lease.release()
    }

    func testLaunchBarrierClosesSettingsRegistrationRace() throws {
        let gate = LocalAgentSettingsOperationGate()
        let usage = LocalAgentRuntimeUsageRegistry()
        let journal = InspectingRuntimeJournal {
            gate.claim(operationID: "settings-race")
        }
        let coordinator = LocalAgentRuntimeLaunchCoordinator(
            maintenanceJournal: journal,
            configurationRevisions: StaticRuntimeConfigurationRevisions(),
            operationGate: gate,
            runtimeUsage: usage
        )

        let lease = try coordinator.acquireUsage(
            configurationID: "local-agent-codex",
            expectedConfigurationRevision: 1
        )

        XCTAssertEqual(journal.settingsClaimResult, false)
        XCTAssertFalse(gate.hasActiveOperation)
        XCTAssertNil(
            usage.acquireMutationFence(configurationID: "local-agent-codex"),
            "A Settings mutation must not enter after the launch barrier registers runtime usage"
        )
        lease.release()
        let fence = try XCTUnwrap(
            usage.acquireMutationFence(configurationID: "local-agent-codex")
        )
        fence.release()
    }

    func testStaleConfigurationRevisionIsRejectedBeforeUsageRegistration() {
        let usage = LocalAgentRuntimeUsageRegistry()
        let coordinator = makeCoordinator(
            entries: [],
            usage: usage,
            configurationRevisions: StaticRuntimeConfigurationRevisions(
                revisions: ["local-agent-codex": 2]
            )
        )

        XCTAssertThrowsError(
            try coordinator.acquireUsage(
                configurationID: "local-agent-codex",
                expectedConfigurationRevision: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAgentRuntimeLaunchAuthorizationError,
                .configurationChanged
            )
        }
        XCTAssertFalse(usage.isInUse(configurationID: "local-agent-codex"))
    }

    private func makeCoordinator(
        entries: [LocalAgentMaintenanceProcessJournalEntry],
        gate: LocalAgentSettingsOperationGate = LocalAgentSettingsOperationGate(),
        usage: LocalAgentRuntimeUsageRegistry,
        configurationRevisions: LocalAgentRuntimeConfigurationRevisionReading = StaticRuntimeConfigurationRevisions()
    ) -> LocalAgentRuntimeLaunchCoordinator {
        LocalAgentRuntimeLaunchCoordinator(
            maintenanceJournal: StaticRuntimeJournal(entries: entries),
            configurationRevisions: configurationRevisions,
            operationGate: gate,
            runtimeUsage: usage
        )
    }

    private func entry(
        referenceID: String,
        state: LocalAgentSettingsProcessState,
        settlement: LocalAgentSettingsProcessSettlement
    ) -> LocalAgentMaintenanceProcessJournalEntry {
        let timestamp = Date(timeIntervalSince1970: 1_786_400_000)
        return LocalAgentMaintenanceProcessJournalEntry(
            referenceID: referenceID,
            operationID: referenceID,
            configurationID: "local-agent-codex",
            action: .login,
            executablePath: "/tools/codex",
            executableIdentityDigest: "sha256:\(String(repeating: "a", count: 64))",
            environmentDigest: "sha256:\(String(repeating: "b", count: 64))",
            processGeneration: 1,
            state: state,
            settlement: settlement,
            preparedAt: timestamp,
            updatedAt: timestamp
        )
    }
}

private final class StaticRuntimeConfigurationRevisions: LocalAgentRuntimeConfigurationRevisionReading {
    private let revisions: [String: Int64]

    init(revisions: [String: Int64] = ["local-agent-codex": 1]) {
        self.revisions = revisions
    }

    func revision(configurationID: String) throws -> Int64? {
        revisions[configurationID]
    }
}

private final class StaticRuntimeJournal: LocalAgentMaintenanceProcessJournalReading {
    let storedEntries: [LocalAgentMaintenanceProcessJournalEntry]

    init(entries: [LocalAgentMaintenanceProcessJournalEntry]) {
        storedEntries = entries
    }

    func entries() throws -> [LocalAgentMaintenanceProcessJournalEntry] {
        storedEntries
    }

    func entry(referenceID: String) throws -> LocalAgentMaintenanceProcessJournalEntry? {
        storedEntries.first { $0.referenceID == referenceID }
    }
}

private final class ThrowingRuntimeJournal: LocalAgentMaintenanceProcessJournalReading {
    enum ReadError: Error { case unavailable }

    func entries() throws -> [LocalAgentMaintenanceProcessJournalEntry] {
        throw ReadError.unavailable
    }

    func entry(referenceID: String) throws -> LocalAgentMaintenanceProcessJournalEntry? {
        throw ReadError.unavailable
    }
}

private final class InspectingRuntimeJournal: LocalAgentMaintenanceProcessJournalReading {
    private let attemptSettingsClaim: () -> Bool
    private(set) var settingsClaimResult: Bool?

    init(attemptSettingsClaim: @escaping () -> Bool) {
        self.attemptSettingsClaim = attemptSettingsClaim
    }

    func entries() throws -> [LocalAgentMaintenanceProcessJournalEntry] {
        settingsClaimResult = attemptSettingsClaim()
        return []
    }

    func entry(referenceID: String) throws -> LocalAgentMaintenanceProcessJournalEntry? {
        nil
    }
}
