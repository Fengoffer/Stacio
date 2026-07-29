import Foundation
import XCTest
@testable import StacioApp

final class FeedbackDiagnosticLogTests: XCTestCase {
    func testStoreEnforcesTTLCountPayloadAndEnvironmentFieldLimits() throws {
        var now = Date(timeIntervalSince1970: 2_000_000)
        let environment = FeedbackDiagnosticLogEnvironment(
            appVersion: String(repeating: "1", count: 400),
            build: String(repeating: "2", count: 400),
            osVersion: String(repeating: "macOS ", count: 100),
            architecture: String(repeating: "arm64", count: 100)
        )
        let store = FeedbackDiagnosticLogStore(
            maxEvents: 64,
            ttl: 24 * 60 * 60,
            maximumEncodedBytes: 24 * 1_024,
            clock: { now },
            routeHashKey: Data(repeating: 0x42, count: 32),
            environmentProvider: { environment }
        )

        store.record(
            level: .warning,
            subsystem: .session,
            eventCode: .sessionConnectionFailed,
            stage: .connect,
            result: .failed,
            errorCategory: .transport,
            resourceIdentities: ["expired-resource"],
            timestamp: now.addingTimeInterval(-(24 * 60 * 60) - 1)
        )
        for index in 0..<100 {
            store.record(
                level: .info,
                subsystem: .session,
                eventCode: .sessionConnected,
                stage: .connect,
                result: .succeeded,
                errorCategory: nil,
                resourceIdentities: (0..<8).map { "resource-\(index)-\($0)" }
            )
        }

        let snapshot = store.snapshot()
        let json = try XCTUnwrap(snapshot.encodedJSONString())

        XCTAssertLessThanOrEqual(snapshot.events.count, 64)
        XCTAssertLessThanOrEqual(json.utf8.count, 24 * 1_024)
        XCTAssertLessThanOrEqual(snapshot.environment.appVersion.count, 80)
        XCTAssertLessThanOrEqual(snapshot.environment.build.count, 80)
        XCTAssertLessThanOrEqual(snapshot.environment.osVersion.count, 160)
        XCTAssertLessThanOrEqual(snapshot.environment.architecture.count, 24)

        let sizeBoundedStore = FeedbackDiagnosticLogStore(
            maxEvents: 64,
            maximumEncodedBytes: 1_024,
            clock: { now },
            routeHashKey: Data(repeating: 0x42, count: 32),
            environmentProvider: { environment }
        )
        for index in 0..<64 {
            sizeBoundedStore.record(
                level: .info,
                subsystem: .session,
                eventCode: .sessionCreated,
                stage: .create,
                result: .succeeded,
                errorCategory: nil,
                resourceIdentities: ["session-\(index)"]
            )
        }
        let sizeBoundedSnapshot = sizeBoundedStore.snapshot()
        let sizeBoundedJSON = try XCTUnwrap(sizeBoundedSnapshot.encodedJSONString())
        XCTAssertLessThanOrEqual(sizeBoundedJSON.utf8.count, 1_024)
        XCTAssertLessThan(sizeBoundedSnapshot.events.count, 64)

        now.addTimeInterval(24 * 60 * 60 + 1)
        XCTAssertTrue(store.snapshot().events.isEmpty)
    }

    func testSnapshotUsesClosedSchemaAndNeverSerializesSensitiveInputs() throws {
        let sensitiveResource = [
            "gateway=192.0.2.10",
            "target=dbadmin@10.20.30.40:22",
            "host=server.internal.example.com",
            "email=operator@example.com",
            "account=SSH@dbadmin@10.20.30.40@internal-account-id",
            "password=never-record-this",
            "token=secret-token",
            "license=STACIO-SECRET-LICENSE",
            "path=/Users/operator/Secrets/private.key",
            "file=customer-production.csv",
            "command=cat /etc/shadow",
            "terminal=raw terminal output",
            "content=remote file contents",
            "clipboard=copied secret",
            "url=https://example.com/path?token=secret"
        ].joined(separator: "|")
        let environment = FeedbackDiagnosticLogEnvironment(
            appVersion: "0.14.2",
            build: "301",
            osVersion: "macOS 27.0",
            architecture: "arm64"
        )
        let store = FeedbackDiagnosticLogStore(
            routeHashKey: Data(repeating: 0x42, count: 32),
            environmentProvider: { environment }
        )
        let otherKeyStore = FeedbackDiagnosticLogStore(
            routeHashKey: Data(repeating: 0x24, count: 32),
            environmentProvider: { environment }
        )

        for target in [store, otherKeyStore] {
            target.record(
                level: .error,
                subsystem: .importFlow,
                eventCode: .sessionImportStage,
                stage: .apply,
                result: .failed,
                errorCategory: .persistence,
                resourceIdentities: [sensitiveResource]
            )
        }

        let snapshot = store.snapshot()
        let json = try XCTUnwrap(snapshot.encodedJSONString())
        let hash = try XCTUnwrap(snapshot.events.first?.resourceHashes.first)
        let otherHash = try XCTUnwrap(otherKeyStore.snapshot().events.first?.resourceHashes.first)

        XCTAssertNotNil(hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertEqual(
            hash,
            FeedbackDiagnosticLogStore(
                routeHashKey: Data(repeating: 0x42, count: 32),
                environmentProvider: { environment }
            ).hashForTesting(sensitiveResource)
        )
        XCTAssertNotEqual(hash, otherHash)
        for forbidden in [
            "192.0.2.10", "10.20.30.40", "server.internal.example.com",
            "operator@example.com", "dbadmin", "internal-account-id",
            "never-record-this", "secret-token", "STACIO-SECRET-LICENSE",
            "/Users/operator", "private.key", "customer-production.csv",
            "cat /etc/shadow", "raw terminal output", "remote file contents",
            "copied secret", "example.com", "?token=secret"
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        XCTAssertEqual(
            Set(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]).keys),
            ["version", "environment", "events"]
        )
    }

    func testRingBufferIsSafeUnderConcurrentRecording() {
        let store = FeedbackDiagnosticLogStore(
            maxEvents: 64,
            routeHashKey: Data(repeating: 0x42, count: 32),
            environmentProvider: {
                FeedbackDiagnosticLogEnvironment(
                    appVersion: "0.14.2",
                    build: "301",
                    osVersion: "macOS 27.0",
                    architecture: "arm64"
                )
            }
        )

        DispatchQueue.concurrentPerform(iterations: 512) { index in
            store.record(
                level: .info,
                subsystem: .session,
                eventCode: .sessionConnected,
                stage: .connect,
                result: .succeeded,
                errorCategory: nil,
                resourceIdentities: ["session-\(index)"]
            )
        }

        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.events.count, 64)
        XCTAssertTrue(snapshot.events.allSatisfy { event in
            event.resourceHashes.allSatisfy {
                $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            }
        })
    }

    func testDiagnosticLogProviderFailureDoesNotPreventFeedbackPayload() throws {
        let configuration = ProductOpsConfiguration(productID: "stacio")
        let context = FeedbackDiagnosticContext.current(
            configuration: configuration,
            diagnosticTraceProvider: { FeedbackDiagnosticTrace(events: []) },
            diagnosticLogProvider: { throw TestError.failed }
        )

        let payload = try FeedbackSubmissionService.payload(
            report: FeedbackReport(
                title: "Connection issue",
                type: .bug,
                description: "Connection could not be established.",
                contact: nil,
                includeDiagnostics: true
            ),
            context: context,
            configuration: configuration
        )

        XCTAssertNotNil(payload)
        XCTAssertNil(payload.diagnostics?[FeedbackDiagnosticLogStore.diagnosticsKey])
    }

    func testConnectionLifecycleHelperRecordsStartSuccessFailureAndDisconnect() throws {
        let store = FeedbackDiagnosticLogStore(
            routeHashKey: Data(repeating: 0x42, count: 32),
            environmentProvider: {
                FeedbackDiagnosticLogEnvironment(
                    appVersion: "0.14.2",
                    build: "301",
                    osVersion: "macOS 27.0",
                    architecture: "arm64"
                )
            }
        )
        let identity = "ssh|192.0.2.10:22|operator"

        FeedbackDiagnosticLogConnectionLifecycle.recordStarted(
            recorder: store,
            resourceIdentity: identity,
            reconnect: false
        )
        FeedbackDiagnosticLogConnectionLifecycle.recordSucceeded(
            recorder: store,
            resourceIdentity: identity,
            reconnect: false
        )
        FeedbackDiagnosticLogConnectionLifecycle.recordFailed(
            recorder: store,
            resourceIdentity: identity,
            reconnect: true,
            errorCategory: .network
        )
        FeedbackDiagnosticLogConnectionLifecycle.recordDisconnected(
            recorder: store,
            resourceIdentity: identity
        )

        XCTAssertEqual(
            store.snapshot().events.map(\.eventCode),
            [
                .sessionConnectionStarted,
                .sessionConnected,
                .sessionReconnectFailed,
                .sessionDisconnected
            ]
        )
        let json = try XCTUnwrap(store.snapshot().encodedJSONString())
        XCTAssertFalse(json.contains("192.0.2.10"))
        XCTAssertFalse(json.contains("operator"))
    }
}

private enum TestError: Error {
    case failed
}
