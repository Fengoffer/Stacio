import Foundation
import XCTest
@testable import StacioApp

final class LocalAgentMaintenanceProcessEvidenceCollectorTests: XCTestCase {
    func testDurableTreeExitEvidenceDoesNotDependOnLaterPIDReuse() throws {
        let inspector = StubProcessInspector(root: .unavailable, group: .unavailable)
        let collector = DarwinLocalAgentMaintenanceEvidenceCollector(inspector: inspector)
        let entry = makeEntry(treeExited: true)

        let evidence = try collector.collectEvidence(for: entry)

        XCTAssertTrue(evidence.processGenerationMatches)
        XCTAssertTrue(evidence.processGroupExited)
        XCTAssertTrue(evidence.processWasIsolated)
        XCTAssertFalse(evidence.businessResultCommitted)
    }

    func testLiveRecordedGroupRemainsUnresolved() throws {
        let identity = observedIdentity()
        let collector = DarwinLocalAgentMaintenanceEvidenceCollector(
            inspector: StubProcessInspector(root: .running(identity), group: .running)
        )

        let evidence = try collector.collectEvidence(for: makeEntry())

        XCTAssertFalse(evidence.processGenerationMatches)
        XCTAssertFalse(evidence.processGroupExited)
        XCTAssertFalse(evidence.processWasIsolated)
    }

    func testMissingRootAndExitedGroupProveIsolation() throws {
        let collector = DarwinLocalAgentMaintenanceEvidenceCollector(
            inspector: StubProcessInspector(root: .missing, group: .exited)
        )

        let evidence = try collector.collectEvidence(for: makeEntry())

        XCTAssertTrue(evidence.processGenerationMatches)
        XCTAssertTrue(evidence.processGroupExited)
        XCTAssertTrue(evidence.processWasIsolated)
    }

    func testReusedPIDAndExitedOldGroupResolveRecordedGeneration() throws {
        let reused = LocalAgentObservedProcessIdentity(
            processIdentifier: 8_100,
            processGroupIdentifier: 9_900,
            trustedStartTime: Date(timeIntervalSince1970: 1_786_500_500)
        )
        let collector = DarwinLocalAgentMaintenanceEvidenceCollector(
            inspector: StubProcessInspector(root: .running(reused), group: .exited)
        )

        let evidence = try collector.collectEvidence(for: makeEntry())

        XCTAssertTrue(evidence.processGenerationMatches)
        XCTAssertTrue(evidence.processGroupExited)
        XCTAssertTrue(evidence.processWasIsolated)
    }

    func testContradictorySameIdentityAndExitedGroupFailsClosed() throws {
        let collector = DarwinLocalAgentMaintenanceEvidenceCollector(
            inspector: StubProcessInspector(root: .running(observedIdentity()), group: .exited)
        )

        let evidence = try collector.collectEvidence(for: makeEntry())

        XCTAssertFalse(evidence.processGenerationMatches)
        XCTAssertTrue(evidence.processGroupExited)
        XCTAssertFalse(evidence.processWasIsolated)
    }

    func testUnavailableGroupObservationThrowsInsteadOfGuessingExit() {
        let collector = DarwinLocalAgentMaintenanceEvidenceCollector(
            inspector: StubProcessInspector(root: .missing, group: .unavailable)
        )

        XCTAssertThrowsError(try collector.collectEvidence(for: makeEntry())) { error in
            XCTAssertEqual(
                error as? LocalAgentMaintenanceEvidenceError,
                .observationUnavailable("maintenance-evidence")
            )
        }
    }

    private func observedIdentity() -> LocalAgentObservedProcessIdentity {
        .init(
            processIdentifier: 8_100,
            processGroupIdentifier: 8_100,
            trustedStartTime: Date(timeIntervalSince1970: 1_786_500_000)
        )
    }

    private func makeEntry(
        treeExited: Bool = false
    ) -> LocalAgentMaintenanceProcessJournalEntry {
        LocalAgentMaintenanceProcessJournalEntry(
            referenceID: "maintenance-evidence",
            operationID: "maintenance-evidence",
            configurationID: "local-agent-evidence",
            action: .login,
            executablePath: "/usr/bin/true",
            executableIdentityDigest: "sha256:" + String(repeating: "a", count: 64),
            environmentDigest: "sha256:" + String(repeating: "b", count: 64),
            processGeneration: 3,
            processIdentifier: 8_100,
            processGroupIdentifier: 8_100,
            trustedProcessStartTime: Date(timeIntervalSince1970: 1_786_500_000),
            state: .stateUnknown,
            settlement: .unknown,
            preparedAt: Date(timeIntervalSince1970: 1_786_499_999),
            startedAt: Date(timeIntervalSince1970: 1_786_500_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_500_100),
            businessResultCommitted: false,
            treeExited: treeExited,
            failureReason: "process_settlement_unknown"
        )
    }
}

private struct StubProcessInspector: LocalAgentProcessInspecting {
    let root: LocalAgentRootProcessObservation
    let group: LocalAgentProcessGroupObservation

    func rootProcess(processIdentifier: Int32) -> LocalAgentRootProcessObservation { root }
    func processGroup(processGroupIdentifier: Int32) -> LocalAgentProcessGroupObservation { group }
}
