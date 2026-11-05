import Foundation
import XCTest
@testable import StacioApp

final class FeedbackDiagnosticTraceTests: XCTestCase {
    func testTraceStoreEnforcesEventLimitAndTTL() {
        var now = Date(timeIntervalSince1970: 2_000_000)
        let store = FeedbackDiagnosticTraceStore(maxEvents: 3, ttl: 60, clock: { now })

        store.record(
            stage: .apply,
            sourceType: .bastionHost,
            vendor: "topsec",
            sessionCount: 1,
            conflictCount: 0,
            result: .succeeded,
            errorCode: nil,
            routeIdentity: "expired-route",
            hasTargetMetadata: true,
            timestamp: now.addingTimeInterval(-61)
        )
        for index in 0..<5 {
            store.record(
                stage: .apply,
                sourceType: .bastionHost,
                vendor: "topsec",
                sessionCount: index,
                conflictCount: 0,
                result: .succeeded,
                errorCode: nil,
                routeIdentity: "route-\(index)",
                hasTargetMetadata: true
            )
        }

        let snapshot = store.snapshot()

        XCTAssertEqual(snapshot.events.count, 3)
        XCTAssertEqual(snapshot.events.map(\.sessionCount), [2, 3, 4])
        XCTAssertFalse(snapshot.events.contains { $0.routeHashes.contains("expired-route") })
        now.addTimeInterval(61)
        XCTAssertTrue(store.snapshot().events.isEmpty)
    }

    func testTraceStorePersistsOnlyRouteHashesAndNeverPlaintextIdentity() throws {
        let routeIdentity = "topsec|gateway=192.0.2.10|target=dbadmin@10.20.30.40:2222|account=internal-account-id"
        let store = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: Date.init,
            routeHashKey: Data(repeating: 0x42, count: 32)
        )
        let otherKeyStore = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: Date.init,
            routeHashKey: Data(repeating: 0x24, count: 32)
        )

        store.record(
            stage: .preview,
            sourceType: .bastionHost,
            vendor: "topsec",
            sessionCount: 1,
            conflictCount: 0,
            result: .ready,
            errorCode: nil,
            routeIdentity: routeIdentity,
            hasTargetMetadata: true
        )
        otherKeyStore.record(
            stage: .preview,
            sourceType: .bastionHost,
            vendor: "topsec",
            sessionCount: 1,
            conflictCount: 0,
            result: .ready,
            errorCode: nil,
            routeIdentity: routeIdentity,
            hasTargetMetadata: true
        )

        let json = try XCTUnwrap(store.snapshot().encodedJSONString())
        XCTAssertFalse(json.contains("192.0.2.10"))
        XCTAssertFalse(json.contains("10.20.30.40"))
        XCTAssertFalse(json.contains("dbadmin"))
        XCTAssertFalse(json.contains("internal-account-id"))
        XCTAssertNotNil(
            store.snapshot().events.first?.routeHashes.first?.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            )
        )
        XCTAssertNotEqual(
            store.snapshot().events.first?.routeHashes.first,
            otherKeyStore.snapshot().events.first?.routeHashes.first
        )
    }

    func testTraceStoreSnapshotIsBoundedEvenWithOversizedValues() throws {
        let store = FeedbackDiagnosticTraceStore(maxEvents: 16, ttl: 86_400, clock: Date.init)
        store.record(
            stage: .apply,
            sourceType: .bastionHost,
            vendor: String(repeating: "v", count: 4_000),
            sessionCount: 1,
            conflictCount: 0,
            result: .failed,
            errorCode: String(repeating: "e", count: 4_000),
            routeIdentity: String(repeating: "r", count: 10_000),
            hasTargetMetadata: false
        )

        let snapshot = store.snapshot()
        XCTAssertLessThanOrEqual(try XCTUnwrap(snapshot.encodedJSONString()).utf8.count, 8 * 1_024)
    }

    func testPreviewFailureErrorCodeSurvivesProductOpsSanitization() throws {
        let store = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: Date.init,
            routeHashKey: Data(repeating: 0x42, count: 32)
        )
        store.record(
            stage: .preview,
            sourceType: .bastionHost,
            vendor: "topsec",
            sessionCount: 1,
            conflictCount: 0,
            result: .failed,
            errorCode: "preview_failed",
            routeIdentity: "topsec|gateway|target",
            hasTargetMetadata: true
        )

        let encoded = try XCTUnwrap(store.snapshot().encodedJSONString())
        let sanitized = try XCTUnwrap(ProductOpsDiagnosticSanitizer.sanitized([
            FeedbackDiagnosticTraceStore.diagnosticsKey: encoded
        ])[FeedbackDiagnosticTraceStore.diagnosticsKey])
        let trace = try XCTUnwrap(FeedbackDiagnosticTrace.validatedTrace(from: sanitized))

        XCTAssertEqual(trace.events.map(\.errorCode), ["preview_failed"])
    }

    func testProductOpsSanitizerRejectsInvalidTraceAndDropsUnknownSensitiveFields() throws {
        let store = FeedbackDiagnosticTraceStore(maxEvents: 16, ttl: 86_400, clock: Date.init)
        store.record(
            stage: .preview,
            sourceType: .bastionHost,
            vendor: "topsec",
            sessionCount: 1,
            conflictCount: 0,
            result: .ready,
            errorCode: nil,
            routeIdentity: "topsec|gateway|target",
            hasTargetMetadata: true
        )
        let safeJSON = try XCTUnwrap(store.snapshot().encodedJSONString())
        let injected = safeJSON.replacingOccurrences(
            of: "{\"events\":",
            with: "{\"gatewayHost\":\"192.0.2.10\",\"username\":\"dbadmin\",\"events\":"
        )

        let sanitized = ProductOpsDiagnosticSanitizer.sanitized([
            FeedbackDiagnosticTraceStore.diagnosticsKey: injected
        ])

        let normalized = try XCTUnwrap(sanitized[FeedbackDiagnosticTraceStore.diagnosticsKey])
        XCTAssertFalse(normalized.contains("192.0.2.10"))
        XCTAssertFalse(normalized.contains("dbadmin"))
        XCTAssertNil(ProductOpsDiagnosticSanitizer.sanitized([
            FeedbackDiagnosticTraceStore.diagnosticsKey: String(repeating: "x", count: 8 * 1_024 + 1)
        ])[FeedbackDiagnosticTraceStore.diagnosticsKey])
        XCTAssertNil(ProductOpsDiagnosticSanitizer.sanitized([
            FeedbackDiagnosticTraceStore.diagnosticsKey: "{\"version\":1,\"events\":[{\"routeHashes\":[\"10.20.30.40\"]}]}"
        ])[FeedbackDiagnosticTraceStore.diagnosticsKey])
        let usernameVendor = safeJSON.replacingOccurrences(
            of: "\"vendor\":\"topsec\"",
            with: "\"vendor\":\"dbadmin\""
        )
        XCTAssertNil(ProductOpsDiagnosticSanitizer.sanitized([
            FeedbackDiagnosticTraceStore.diagnosticsKey: usernameVendor
        ])[FeedbackDiagnosticTraceStore.diagnosticsKey])

        let oldDate = Date().addingTimeInterval(-25 * 60 * 60)
        let oldStore = FeedbackDiagnosticTraceStore(
            maxEvents: 16,
            ttl: 86_400,
            clock: { oldDate },
            routeHashKey: Data(repeating: 0x42, count: 32)
        )
        oldStore.record(
            stage: .preview,
            sourceType: .bastionHost,
            vendor: "topsec",
            sessionCount: 1,
            conflictCount: 0,
            result: .ready,
            errorCode: nil,
            routeIdentity: "expired-route",
            hasTargetMetadata: true
        )
        XCTAssertNil(ProductOpsDiagnosticSanitizer.sanitized([
            FeedbackDiagnosticTraceStore.diagnosticsKey: try XCTUnwrap(oldStore.snapshot().encodedJSONString())
        ])[FeedbackDiagnosticTraceStore.diagnosticsKey])
    }
}
