import Foundation
import XCTest
@testable import StacioApp

final class LocalAgentMaintenanceProcessJournalStoreTests: XCTestCase {
    func testDurableLifecycleRequiresWholeTreeAndBusinessCommit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()

        let prepared = try fixture.prepare(in: store)
        XCTAssertEqual(prepared.state, .prepared)
        XCTAssertEqual(prepared.processGeneration, 1)

        XCTAssertEqual(
            try store.transition(referenceID: fixture.referenceID, event: .beginStart).state,
            .starting
        )
        XCTAssertThrowsError(try store.transition(
            referenceID: fixture.referenceID,
            event: .processStarted,
            processIdentifier: 1200
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentMaintenanceProcessJournalStoreError,
                .missingProcessIdentity(fixture.referenceID)
            )
        }
        let running = try store.transition(
            referenceID: fixture.referenceID,
            event: .processStarted,
            processIdentifier: 1200,
            processGroupIdentifier: 1200,
            trustedProcessStartTime: fixture.now
        )
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.processIdentifier, 1200)
        XCTAssertEqual(running.processGroupIdentifier, 1200)

        let stopping = try store.transition(referenceID: fixture.referenceID, event: .ptyExited)
        XCTAssertEqual(stopping.state, .stopping)
        XCTAssertFalse(stopping.treeExited)

        let completed = try store.transition(
            referenceID: fixture.referenceID,
            event: .treeExited(businessResultCommitted: true),
            exitCode: 0
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.settlement, .exited)
        XCTAssertTrue(completed.treeExited)
        XCTAssertTrue(completed.businessResultCommitted)
        XCTAssertNotNil(completed.finishedAt)
    }

    func testKnownCancellationAndFailureAreTerminalOnlyAfterTreeExit() throws {
        for (suffix, event, expected) in [
            ("cancel", LocalAgentSettingsProcessEvent.treeExitedCancelled, LocalAgentSettingsProcessState.cancelled),
            ("failed", LocalAgentSettingsProcessEvent.treeExitedFailed, LocalAgentSettingsProcessState.failed)
        ] {
            let fixture = try Fixture(suffix: suffix)
            defer { fixture.cleanup() }
            let store = try fixture.makeStore()
            try fixture.prepare(in: store)
            _ = try store.transition(referenceID: fixture.referenceID, event: .beginStart)
            _ = try store.transition(
                referenceID: fixture.referenceID,
                event: .processStarted,
                processIdentifier: 2000,
                processGroupIdentifier: 2000,
                trustedProcessStartTime: fixture.now
            )

            let terminal = try store.transition(
                referenceID: fixture.referenceID,
                event: event,
                exitCode: expected == .cancelled ? 130 : 1,
                failureReason: expected == .failed ? "maintenance_exit_1" : nil
            )

            XCTAssertEqual(terminal.state, expected)
            XCTAssertTrue(terminal.treeExited)
            XCTAssertNotNil(terminal.finishedAt)
        }
    }

    func testUnknownSettlementCanPersistIdentityWhenProcessStartedWriteWasLost() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        try fixture.prepare(in: store)
        _ = try store.transition(referenceID: fixture.referenceID, event: .beginStart)

        let unknown = try store.transition(
            referenceID: fixture.referenceID,
            event: .settlementUnknown,
            processIdentifier: 2_500,
            processGroupIdentifier: 2_500,
            trustedProcessStartTime: fixture.now,
            failureReason: "process_identity_persistence_failed"
        )

        XCTAssertEqual(unknown.state, .stateUnknown)
        XCTAssertEqual(unknown.processIdentifier, 2_500)
        XCTAssertEqual(unknown.processGroupIdentifier, 2_500)
        XCTAssertEqual(unknown.trustedProcessStartTime, fixture.now)
        XCTAssertEqual(unknown.startedAt, fixture.now)
        XCTAssertFalse(unknown.treeExited)
    }

    func testReopeningNonterminalEntryRequiresReconciliation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            let store = try fixture.makeStore()
            try fixture.prepare(in: store)
            _ = try store.transition(referenceID: fixture.referenceID, event: .beginStart)
            _ = try store.transition(
                referenceID: fixture.referenceID,
                event: .processStarted,
                processIdentifier: 3100,
                processGroupIdentifier: 3100,
                trustedProcessStartTime: fixture.now
            )
        }

        let reopened = try fixture.makeStore()
        let unknown = try XCTUnwrap(reopened.entry(referenceID: fixture.referenceID))
        XCTAssertEqual(unknown.state, .stateUnknown)
        XCTAssertEqual(unknown.settlement, .unknown)
        XCTAssertEqual(unknown.failureReason, "reopened_after_crash")
        XCTAssertNil(unknown.finishedAt)

        XCTAssertThrowsError(try reopened.reconcile(
            referenceID: fixture.referenceID,
            evidence: .init(
                processGenerationMatches: true,
                processGroupExited: false,
                businessResultCommitted: false,
                processWasIsolated: true
            )
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentMaintenanceProcessJournalStoreError,
                .insufficientReconciliationEvidence(fixture.referenceID)
            )
        }
        XCTAssertEqual(
            try reopened.entry(referenceID: fixture.referenceID)?.state,
            .stateUnknown
        )

        let isolated = try reopened.reconcile(
            referenceID: fixture.referenceID,
            evidence: .init(
                processGenerationMatches: true,
                processGroupExited: true,
                businessResultCommitted: false,
                processWasIsolated: true
            )
        )
        XCTAssertEqual(isolated.state, .isolated)
        XCTAssertEqual(isolated.settlement, .isolated)
    }

    func testReopeningTerminalEntryDoesNotRegressIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        do {
            let store = try fixture.makeStore()
            try fixture.prepare(in: store)
            _ = try store.transition(referenceID: fixture.referenceID, event: .startFailed)
        }

        let reopened = try fixture.makeStore()
        XCTAssertEqual(try reopened.entry(referenceID: fixture.referenceID)?.state, .failed)
    }

    func testPrepareIsIdempotentAndGenerationIsMonotonicAcrossStoreInstances() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstStore = try fixture.makeStore()
        let secondStore = try fixture.makeStore()

        let first = try fixture.prepare(in: firstStore)
        let replay = try fixture.prepare(in: secondStore)
        XCTAssertEqual(replay, first)

        let second = try secondStore.prepare(
            referenceID: "maintenance-ref-2",
            operationID: "maintenance-op-2",
            configurationID: "local-agent-2",
            action: .logout,
            executablePath: fixture.executable.path,
            executableIdentityDigest: fixture.executableDigest,
            environmentDigest: fixture.environmentDigest
        )
        XCTAssertEqual(second.processGeneration, first.processGeneration + 1)
        XCTAssertEqual(try firstStore.entries().count, 2)

        XCTAssertThrowsError(try secondStore.prepare(
            referenceID: fixture.referenceID,
            operationID: fixture.operationID,
            configurationID: "different-configuration",
            action: .login,
            executablePath: fixture.executable.path,
            executableIdentityDigest: fixture.executableDigest,
            environmentDigest: fixture.environmentDigest
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentMaintenanceProcessJournalStoreError,
                .duplicateOperation(fixture.operationID)
            )
        }
    }

    func testConcurrentStoreInstancesDoNotLoseEntries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let firstStore = try fixture.makeStore()
        let secondStore = try fixture.makeStore()
        let queue = DispatchQueue(label: "journal-concurrency", attributes: .concurrent)
        let group = DispatchGroup()
        let resultLock = NSLock()
        var failures: [Error] = []

        for index in 0..<20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    _ = try (index.isMultiple(of: 2) ? firstStore : secondStore).prepare(
                        referenceID: "reference-\(index)",
                        operationID: "operation-\(index)",
                        configurationID: "configuration-\(index)",
                        action: index.isMultiple(of: 2) ? .login : .logout,
                        executablePath: fixture.executable.path,
                        executableIdentityDigest: fixture.executableDigest,
                        environmentDigest: fixture.environmentDigest
                    )
                } catch {
                    resultLock.withLock { failures.append(error) }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(failures.isEmpty, "Unexpected failures: \(failures)")
        let entries = try firstStore.entries()
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(Set(entries.map(\.processGeneration)).count, entries.count)
    }

    func testJournalPermissionsAndPayloadContainNoCommandOrEnvironmentValues() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()
        try fixture.prepare(in: store)
        let payload = try String(contentsOf: fixture.fileURL, encoding: .utf8)

        XCTAssertFalse(payload.contains("login status"))
        XCTAssertFalse(payload.contains("SECRET_TOKEN"))
        XCTAssertFalse(payload.contains("secret-value"))
        XCTAssertEqual(try permissions(at: fixture.fileURL) & 0o777, 0o600)
        XCTAssertEqual(try permissions(at: fixture.root) & 0o777, 0o700)
    }

    func testCorruptStateCombinationFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let invalid = LocalAgentMaintenanceProcessJournalEntry(
            referenceID: fixture.referenceID,
            operationID: fixture.operationID,
            configurationID: fixture.configurationID,
            action: .login,
            executablePath: fixture.executable.path,
            executableIdentityDigest: fixture.executableDigest,
            environmentDigest: fixture.environmentDigest,
            processGeneration: 1,
            state: .running,
            settlement: .pending,
            preparedAt: fixture.now,
            updatedAt: fixture.now
        )
        let data = try JSONEncoder().encode(TestEnvelope(schemaVersion: 1, entries: [invalid]))
        try data.write(to: fixture.fileURL, options: .atomic)

        XCTAssertThrowsError(try fixture.makeStore()) { error in
            XCTAssertEqual(
                error as? LocalAgentMaintenanceProcessJournalStoreError,
                .invalidEntry(fixture.referenceID)
            )
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }
}

private struct TestEnvelope: Codable {
    let schemaVersion: Int
    let entries: [LocalAgentMaintenanceProcessJournalEntry]
}

private struct Fixture {
    let root: URL
    let fileURL: URL
    let executable: URL
    let referenceID: String
    let operationID: String
    let configurationID: String
    let executableDigest: String
    let environmentDigest = "sha256:" + String(repeating: "b", count: 64)
    let now = Date(timeIntervalSince1970: 1_786_500_000)

    init(suffix: String = UUID().uuidString.lowercased()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maintenance-journal-\(suffix)", isDirectory: true)
        fileURL = root.appendingPathComponent("journal-v1.json")
        executable = root.appendingPathComponent("codex")
        referenceID = "maintenance-ref-\(suffix)"
        operationID = "maintenance-op-\(suffix)"
        configurationID = "local-agent-\(suffix)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        executableDigest = try XCTUnwrap(
            LocalAgentConfigurationIntegrity.executableDigest(path: executable.path)
        )
    }

    func makeStore() throws -> LocalAgentMaintenanceProcessJournalStore {
        try LocalAgentMaintenanceProcessJournalStore(
            fileURL: fileURL,
            now: { now }
        )
    }

    @discardableResult
    func prepare(
        in store: LocalAgentMaintenanceProcessJournalStore
    ) throws -> LocalAgentMaintenanceProcessJournalEntry {
        try store.prepare(
            referenceID: referenceID,
            operationID: operationID,
            configurationID: configurationID,
            action: .login,
            executablePath: executable.path,
            executableIdentityDigest: executableDigest,
            environmentDigest: environmentDigest
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
