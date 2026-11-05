import Foundation
import XCTest
@testable import StacioApp

final class DeviceMetricsAlertCoordinatorTests: XCTestCase {
    func testConsecutiveThresholdBreachesTriggerNotification() {
        let notifier = RecordingDeviceMetricsAlertNotifier()
        let coordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: {
                AppSettings(
                    deviceMetricsCPUAlertThresholdPercent: 90,
                    deviceMetricsAlertConsecutiveRefreshCount: 2
                )
            },
            notifier: notifier
        )

        coordinator.process(
            snapshot: .alertSample(cpuUsage: 0.95),
            runtimeID: "term_metrics",
            sessionTitle: "prod@example.com"
        )
        coordinator.process(
            snapshot: .alertSample(cpuUsage: 0.96),
            runtimeID: "term_metrics",
            sessionTitle: "prod@example.com"
        )

        XCTAssertEqual(notifier.payloads.count, 1)
        XCTAssertEqual(notifier.payloads[0].runtimeID, "term_metrics")
        XCTAssertEqual(notifier.payloads[0].metricID, "cpu")
        XCTAssertEqual(notifier.payloads[0].body, "[prod@example.com] CPU 使用率 96%，达到/超过阈值 90%")
    }

    func testEqualThresholdCountsAsBreach() {
        let notifier = RecordingDeviceMetricsAlertNotifier()
        let coordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: {
                AppSettings(
                    deviceMetricsCPUAlertThresholdPercent: 90,
                    deviceMetricsAlertConsecutiveRefreshCount: 1
                )
            },
            notifier: notifier
        )

        coordinator.process(
            snapshot: .alertSample(cpuUsage: 0.90),
            runtimeID: "term_metrics",
            sessionTitle: "prod@example.com"
        )

        XCTAssertEqual(notifier.payloads.count, 1)
        XCTAssertEqual(notifier.payloads[0].body, "[prod@example.com] CPU 使用率 90%，达到/超过阈值 90%")
    }

    func testSingleJitterAboveThresholdDoesNotTriggerNotification() {
        let notifier = RecordingDeviceMetricsAlertNotifier()
        let coordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: {
                AppSettings(
                    deviceMetricsCPUAlertThresholdPercent: 90,
                    deviceMetricsAlertConsecutiveRefreshCount: 2
                )
            },
            notifier: notifier
        )

        coordinator.process(snapshot: .alertSample(cpuUsage: 0.94), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(cpuUsage: 0.40), runtimeID: "term_metrics", sessionTitle: "prod")

        XCTAssertTrue(notifier.payloads.isEmpty)
    }

    func testAlertDoesNotRepeatUntilMetricRecovers() {
        let notifier = RecordingDeviceMetricsAlertNotifier()
        let coordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: {
                AppSettings(
                    deviceMetricsMemoryAlertThresholdPercent: 90,
                    deviceMetricsAlertConsecutiveRefreshCount: 2
                )
            },
            notifier: notifier
        )

        coordinator.process(snapshot: .alertSample(memoryUsage: 0.91), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(memoryUsage: 0.92), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(memoryUsage: 0.93), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(memoryUsage: 0.94), runtimeID: "term_metrics", sessionTitle: "prod")

        XCTAssertEqual(notifier.payloads.count, 1)
        XCTAssertEqual(notifier.payloads[0].metricID, "memory")
    }

    func testAlertCanTriggerAgainAfterMetricRecovers() {
        let notifier = RecordingDeviceMetricsAlertNotifier()
        let coordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: {
                AppSettings(
                    deviceMetricsDiskAlertThresholdPercent: 90,
                    deviceMetricsAlertConsecutiveRefreshCount: 2
                )
            },
            notifier: notifier
        )

        coordinator.process(snapshot: .alertSample(diskUsage: 0.91), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(diskUsage: 0.92), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(diskUsage: 0.20), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(diskUsage: 0.93), runtimeID: "term_metrics", sessionTitle: "prod")
        coordinator.process(snapshot: .alertSample(diskUsage: 0.94), runtimeID: "term_metrics", sessionTitle: "prod")

        XCTAssertEqual(notifier.payloads.count, 2)
        XCTAssertEqual(notifier.payloads.map(\.metricID), ["disk:/", "disk:/"])
    }

    func testDisabledAlertSettingDoesNotNotify() {
        let notifier = RecordingDeviceMetricsAlertNotifier()
        let coordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: {
                AppSettings(
                    deviceMetricsAlertEnabled: false,
                    deviceMetricsCPUAlertThresholdPercent: 10,
                    deviceMetricsAlertConsecutiveRefreshCount: 1
                )
            },
            notifier: notifier
        )

        coordinator.process(snapshot: .alertSample(cpuUsage: 0.99), runtimeID: "term_metrics", sessionTitle: "prod")

        XCTAssertTrue(notifier.payloads.isEmpty)
    }

    func testInvalidThresholdsFallBackToDefaultNinetyPercent() {
        XCTAssertEqual(AppSettings.normalizedDeviceMetricsAlertThresholdPercent(-1), 90)
        XCTAssertEqual(AppSettings.normalizedDeviceMetricsAlertThresholdPercent(101), 90)
        XCTAssertEqual(AppSettings.normalizedDeviceMetricsAlertThresholdPercent(0), 0)
        XCTAssertEqual(AppSettings.normalizedDeviceMetricsAlertThresholdPercent(100), 100)
    }
}

private final class RecordingDeviceMetricsAlertNotifier: DeviceMetricsAlertNotificationDelivering {
    private(set) var payloads: [DeviceMetricsAlertNotificationPayload] = []

    func deliver(_ payload: DeviceMetricsAlertNotificationPayload) {
        payloads.append(payload)
    }
}

private extension DeviceMetricsDisplaySnapshot {
    static func alertSample(
        cpuUsage: Double? = 0.10,
        memoryUsage: Double = 0.10,
        diskUsage: Double = 0.10
    ) -> DeviceMetricsDisplaySnapshot {
        DeviceMetricsDisplaySnapshot(
            cpuUsage: cpuUsage,
            memory: DeviceMemoryDisplayUsage(
                usedBytes: UInt64(memoryUsage * 1_000),
                totalBytes: 1_000
            ),
            networks: [],
            disks: [
                DeviceDiskDisplayUsage(
                    mountPath: "/",
                    usedBytes: UInt64(diskUsage * 1_000),
                    totalBytes: 1_000
                )
            ]
        )
    }
}
