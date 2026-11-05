import XCTest
@testable import StacioApp

final class UserNotificationDeliveryTests: XCTestCase {
    func testNotificationPayloadDefaultsToUniqueAutomaticRetention() {
        let payload = StacioUserNotificationPayload(
            identifier: "Stacio.commandCompletion.runtime.1",
            title: "命令已完成",
            body: "完成",
            runtimeID: "runtime"
        )

        XCTAssertEqual(payload.retentionPolicy, .uniqueAutomatic)
    }

    func testDeviceMetricAdapterUsesReplaceableAutomaticRetention() throws {
        let delivery = RecordingNotificationDeliveryForRetentionTests()
        let notifier = StacioUserNotificationDeviceMetricsAlertNotifier(delivery: delivery)

        notifier.deliver(DeviceMetricsAlertNotificationPayload(
            identifier: "Stacio.deviceMetricsAlert.runtime.cpu",
            runtimeID: "runtime",
            metricID: "cpu",
            title: "CPU 使用率告警",
            body: "CPU 使用率过高"
        ))

        XCTAssertEqual(try XCTUnwrap(delivery.payloads.first).retentionPolicy, .replaceableAutomatic)
    }

    func testGenerationGateRejectsDeliveryAfterNotificationWasRemoved() {
        let gate = NotificationDeliveryGenerationGate()
        let registration = gate.begin(identifier: "Stacio.transfer.job_one")

        let invalidatedIdentifiers = gate.invalidate(identifiers: ["Stacio.transfer.job_one"])

        XCTAssertFalse(gate.isCurrent(registration.token))
        XCTAssertEqual(invalidatedIdentifiers, [registration.token.physicalIdentifier])
    }

    func testGenerationGateUsesDistinctPhysicalIdentifiersAndKeepsOnlyNewestDelivery() {
        let gate = NotificationDeliveryGenerationGate()
        let first = gate.begin(identifier: "Stacio.transfer.job_one")
        let second = gate.begin(identifier: "Stacio.transfer.job_one")

        XCTAssertNotEqual(first.token.physicalIdentifier, second.token.physicalIdentifier)
        XCTAssertEqual(second.supersededPhysicalIdentifiers, [first.token.physicalIdentifier])
        XCTAssertFalse(gate.isCurrent(first.token))
        XCTAssertTrue(gate.isCurrent(second.token))
    }

    func testFinishingStaleDeliveryCannotInvalidateNewPhysicalRequest() {
        let gate = NotificationDeliveryGenerationGate()
        let first = gate.begin(identifier: "Stacio.transfer.job_one")
        let second = gate.begin(identifier: "Stacio.transfer.job_one")

        gate.finish(first.token)

        XCTAssertTrue(gate.isCurrent(second.token))
        XCTAssertEqual(
            gate.invalidate(identifiers: ["Stacio.transfer.job_one"]),
            [second.token.physicalIdentifier]
        )
    }

    func testFinishingSuccessfulAutomaticDeliveryReleasesGenerationState() {
        let gate = NotificationDeliveryGenerationGate()
        let registration = gate.begin(identifier: "Stacio.commandCompletion.runtime.1")
        XCTAssertEqual(gate.trackedIdentifierCountForTesting, 1)

        gate.finish(registration.token)

        XCTAssertEqual(gate.trackedIdentifierCountForTesting, 0)
        XCTAssertFalse(gate.isCurrent(registration.token))
        XCTAssertEqual(
            gate.invalidate(identifiers: ["Stacio.commandCompletion.runtime.1"]),
            []
        )
    }
}

private final class RecordingNotificationDeliveryForRetentionTests: StacioUserNotificationDelivering {
    private(set) var payloads: [StacioUserNotificationPayload] = []

    func deliver(_ payload: StacioUserNotificationPayload) {
        payloads.append(payload)
    }

    func setActivationHandler(_ handler: @escaping (String) -> Void) {}
}
