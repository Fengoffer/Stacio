import Foundation

public struct DeviceMetricsAlertNotificationPayload: Equatable {
    public let identifier: String
    public let runtimeID: String
    public let metricID: String
    public let title: String
    public let body: String

    public init(identifier: String, runtimeID: String, metricID: String, title: String, body: String) {
        self.identifier = identifier
        self.runtimeID = runtimeID
        self.metricID = metricID
        self.title = title
        self.body = body
    }
}

public protocol DeviceMetricsAlertNotificationDelivering: AnyObject {
    func deliver(_ payload: DeviceMetricsAlertNotificationPayload)
}

public protocol DeviceMetricsAlertNotificationActivating: AnyObject {
    func setActivationHandler(_ handler: @escaping (String) -> Void)
}

public enum DeviceMetricsAlertThresholdUnit: Equatable {
    case percent
    case megabytesPerSecond
}

public struct DeviceMetricsAlertThreshold: Equatable {
    public let displayValue: Double
    public let absoluteValue: Double
    public let unit: DeviceMetricsAlertThresholdUnit

    public init(displayValue: Double, absoluteValue: Double, unit: DeviceMetricsAlertThresholdUnit) {
        self.displayValue = displayValue
        self.absoluteValue = absoluteValue
        self.unit = unit
    }
}

public enum DeviceMetricsAlertMetric: Int, CaseIterable {
    case cpuUsage
    case memoryUsage
    case diskUsage
    case networkIO
    case diskIO

    public var displayName: String {
        switch self {
        case .cpuUsage:
            return "CPU"
        case .memoryUsage:
            return "内存"
        case .diskUsage:
            return "磁盘"
        case .networkIO:
            return "网络 I/O"
        case .diskIO:
            return "磁盘读写"
        }
    }

    public var accessibilityID: String {
        switch self {
        case .cpuUsage:
            return "cpu"
        case .memoryUsage:
            return "memory"
        case .diskUsage:
            return "disk"
        case .networkIO:
            return "networkIO"
        case .diskIO:
            return "diskIO"
        }
    }

    public var thresholdUnit: DeviceMetricsAlertThresholdUnit {
        switch self {
        case .cpuUsage, .memoryUsage, .diskUsage:
            return .percent
        case .networkIO, .diskIO:
            return .megabytesPerSecond
        }
    }

    public var thresholdUnitLabel: String {
        switch thresholdUnit {
        case .percent:
            return "%"
        case .megabytesPerSecond:
            return "MB/s"
        }
    }
}

public final class NoopDeviceMetricsAlertNotifier: DeviceMetricsAlertNotificationDelivering {
    public init() {}
    public func deliver(_ payload: DeviceMetricsAlertNotificationPayload) {}
}

public final class StacioUserNotificationDeviceMetricsAlertNotifier: DeviceMetricsAlertNotificationDelivering {
    private let delivery: StacioUserNotificationDelivering

    public init(delivery: StacioUserNotificationDelivering) {
        self.delivery = delivery
    }

    public func deliver(_ payload: DeviceMetricsAlertNotificationPayload) {
        delivery.deliver(StacioUserNotificationPayload(
            identifier: payload.identifier,
            title: payload.title,
            body: payload.body,
            runtimeID: payload.runtimeID
        ))
    }
}

public final class ActivatingDeviceMetricsAlertNotifier: DeviceMetricsAlertNotificationDelivering, DeviceMetricsAlertNotificationActivating {
    private let backing: StacioUserNotificationDeviceMetricsAlertNotifier
    private let delivery: StacioUserNotificationDelivering

    public init(delivery: StacioUserNotificationDelivering) {
        self.delivery = delivery
        self.backing = StacioUserNotificationDeviceMetricsAlertNotifier(delivery: delivery)
    }

    public func setActivationHandler(_ handler: @escaping (String) -> Void) {
        delivery.setActivationHandler(handler)
    }

    public func deliver(_ payload: DeviceMetricsAlertNotificationPayload) {
        backing.deliver(payload)
    }
}

public final class DeviceMetricsAlertCoordinator {
    private struct MetricState {
        var consecutiveBreaches = 0
        var hasAlerted = false
    }

    private struct MetricReading {
        let id: String
        let displayName: String
        let usageFraction: Double
        let thresholdPercent: Int
    }

    private enum ThresholdKey {
        static let networkIOBytesPerSecond = "Stacio.Settings.deviceMetricsNetworkIOAlertThresholdBytesPerSecond"
        static let diskIOBytesPerSecond = "Stacio.Settings.deviceMetricsDiskIOAlertThresholdBytesPerSecond"
    }

    private static let bytesPerMegabyte = 1_048_576.0
    private static let defaultNetworkIOThresholdMegabytesPerSecond = 10.0
    private static let defaultDiskIOThresholdMegabytesPerSecond = 50.0

    private let settingsProvider: () -> AppSettings
    private let notifier: DeviceMetricsAlertNotificationDelivering
    private let thresholdDefaults: UserDefaults
    private var statesByRuntimeAndMetric: [String: MetricState] = [:]

    public init(
        settingsProvider: @escaping () -> AppSettings,
        notifier: DeviceMetricsAlertNotificationDelivering,
        thresholdDefaults: UserDefaults = .standard
    ) {
        self.settingsProvider = settingsProvider
        self.notifier = notifier
        self.thresholdDefaults = thresholdDefaults
    }

    public func process(snapshot: DeviceMetricsDisplaySnapshot, runtimeID: String, sessionTitle: String) {
        guard runtimeID.isEmpty == false else { return }
        let settings = settingsProvider()
        guard settings.deviceMetricsAlertEnabled else {
            clearStates(forRuntimeID: runtimeID)
            return
        }

        for reading in readings(from: snapshot, settings: settings) {
            update(reading: reading, runtimeID: runtimeID, sessionTitle: sessionTitle, settings: settings)
        }
    }

    public func threshold(
        for metric: DeviceMetricsAlertMetric,
        settingsStore: AppSettingsStore = .shared
    ) -> DeviceMetricsAlertThreshold {
        let settings = settingsStore.snapshot()
        switch metric {
        case .cpuUsage:
            return percentThreshold(settings.deviceMetricsCPUAlertThresholdPercent)
        case .memoryUsage:
            return percentThreshold(settings.deviceMetricsMemoryAlertThresholdPercent)
        case .diskUsage:
            return percentThreshold(settings.deviceMetricsDiskAlertThresholdPercent)
        case .networkIO:
            let bytes = storedIOThresholdBytes(
                forKey: ThresholdKey.networkIOBytesPerSecond,
                defaultMegabytesPerSecond: Self.defaultNetworkIOThresholdMegabytesPerSecond
            )
            return ioThreshold(bytesPerSecond: bytes)
        case .diskIO:
            let bytes = storedIOThresholdBytes(
                forKey: ThresholdKey.diskIOBytesPerSecond,
                defaultMegabytesPerSecond: Self.defaultDiskIOThresholdMegabytesPerSecond
            )
            return ioThreshold(bytesPerSecond: bytes)
        }
    }

    public func updateThreshold(
        _ displayValue: Double,
        for metric: DeviceMetricsAlertMetric,
        settingsStore: AppSettingsStore = .shared
    ) {
        switch metric {
        case .cpuUsage:
            let value = AppSettings.normalizedDeviceMetricsAlertThresholdPercent(Int(displayValue.rounded()))
            settingsStore.update { settings in
                settings.deviceMetricsCPUAlertThresholdPercent = value
            }
        case .memoryUsage:
            let value = AppSettings.normalizedDeviceMetricsAlertThresholdPercent(Int(displayValue.rounded()))
            settingsStore.update { settings in
                settings.deviceMetricsMemoryAlertThresholdPercent = value
            }
        case .diskUsage:
            let value = AppSettings.normalizedDeviceMetricsAlertThresholdPercent(Int(displayValue.rounded()))
            settingsStore.update { settings in
                settings.deviceMetricsDiskAlertThresholdPercent = value
            }
        case .networkIO:
            storeIOThreshold(displayValue, forKey: ThresholdKey.networkIOBytesPerSecond)
        case .diskIO:
            storeIOThreshold(displayValue, forKey: ThresholdKey.diskIOBytesPerSecond)
        }
    }

    public func isBreachingThreshold(
        value: Double,
        for metric: DeviceMetricsAlertMetric,
        settingsStore: AppSettingsStore = .shared
    ) -> Bool {
        let threshold = threshold(for: metric, settingsStore: settingsStore)
        switch threshold.unit {
        case .percent:
            return value >= threshold.absoluteValue
        case .megabytesPerSecond:
            return value >= threshold.absoluteValue
        }
    }

    private func update(
        reading: MetricReading,
        runtimeID: String,
        sessionTitle: String,
        settings: AppSettings
    ) {
        let key = "\(runtimeID):\(reading.id)"
        var state = statesByRuntimeAndMetric[key] ?? MetricState()
        let thresholdFraction = Double(reading.thresholdPercent) / 100.0
        let isBreaching = reading.usageFraction >= thresholdFraction

        if isBreaching {
            state.consecutiveBreaches += 1
            if state.hasAlerted == false,
               state.consecutiveBreaches >= settings.deviceMetricsAlertConsecutiveRefreshCount {
                state.hasAlerted = true
                notifier.deliver(payload(
                    reading: reading,
                    runtimeID: runtimeID,
                    sessionTitle: sessionTitle
                ))
            }
        } else {
            state = MetricState()
        }
        statesByRuntimeAndMetric[key] = state
    }

    private func readings(from snapshot: DeviceMetricsDisplaySnapshot, settings: AppSettings) -> [MetricReading] {
        var values: [MetricReading] = []
        if let cpuUsage = snapshot.cpuUsage {
            values.append(MetricReading(
                id: "cpu",
                displayName: "CPU",
                usageFraction: cpuUsage,
                thresholdPercent: settings.deviceMetricsCPUAlertThresholdPercent
            ))
        }
        values.append(MetricReading(
            id: "memory",
            displayName: "内存",
            usageFraction: snapshot.memory.usageFraction,
            thresholdPercent: settings.deviceMetricsMemoryAlertThresholdPercent
        ))
        values.append(contentsOf: snapshot.disks.map { disk in
            MetricReading(
                id: "disk:\(disk.mountPath)",
                displayName: "磁盘",
                usageFraction: disk.usageFraction,
                thresholdPercent: settings.deviceMetricsDiskAlertThresholdPercent
            )
        })
        return values
    }

    private func payload(
        reading: MetricReading,
        runtimeID: String,
        sessionTitle rawSessionTitle: String
    ) -> DeviceMetricsAlertNotificationPayload {
        let sessionTitle = rawSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = sessionTitle.isEmpty ? runtimeID : sessionTitle
        let currentPercent = Int((reading.usageFraction * 100).rounded())
        let body = "[\(displayTitle)] \(reading.displayName) 使用率 \(currentPercent)%，达到/超过阈值 \(reading.thresholdPercent)%"
        return DeviceMetricsAlertNotificationPayload(
            identifier: "Stacio.deviceMetricsAlert.\(runtimeID).\(reading.id)",
            runtimeID: runtimeID,
            metricID: reading.id,
            title: L10n.DeviceMetricsAlerts.title,
            body: body
        )
    }

    private func clearStates(forRuntimeID runtimeID: String) {
        statesByRuntimeAndMetric = statesByRuntimeAndMetric.filter { key, _ in
            key.hasPrefix("\(runtimeID):") == false
        }
    }

    private func percentThreshold(_ percent: Int) -> DeviceMetricsAlertThreshold {
        let normalized = AppSettings.normalizedDeviceMetricsAlertThresholdPercent(percent)
        return DeviceMetricsAlertThreshold(
            displayValue: Double(normalized),
            absoluteValue: Double(normalized) / 100.0,
            unit: .percent
        )
    }

    private func ioThreshold(bytesPerSecond: Double) -> DeviceMetricsAlertThreshold {
        let normalizedBytes = Self.normalizedIOThresholdBytesPerSecond(bytesPerSecond)
        return DeviceMetricsAlertThreshold(
            displayValue: normalizedBytes / Self.bytesPerMegabyte,
            absoluteValue: normalizedBytes,
            unit: .megabytesPerSecond
        )
    }

    private func storedIOThresholdBytes(forKey key: String, defaultMegabytesPerSecond: Double) -> Double {
        if let doubleValue = thresholdDefaults.object(forKey: key) as? Double {
            return Self.normalizedIOThresholdBytesPerSecond(doubleValue)
        }
        if let intValue = thresholdDefaults.object(forKey: key) as? Int {
            return Self.normalizedIOThresholdBytesPerSecond(Double(intValue))
        }
        return defaultMegabytesPerSecond * Self.bytesPerMegabyte
    }

    private func storeIOThreshold(_ displayValue: Double, forKey key: String) {
        let megabytesPerSecond = Self.normalizedIOThresholdMegabytesPerSecond(displayValue)
        thresholdDefaults.set(megabytesPerSecond * Self.bytesPerMegabyte, forKey: key)
    }

    private static func normalizedIOThresholdMegabytesPerSecond(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }
        return min(max(value, 0), 1_048_576)
    }

    private static func normalizedIOThresholdBytesPerSecond(_ value: Double) -> Double {
        guard value.isFinite else {
            return 0
        }
        return min(max(value, 0), 1_048_576 * bytesPerMegabyte)
    }
}
