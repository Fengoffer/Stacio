import Foundation
import StacioCoreBindings

public struct DeviceMemoryDisplayUsage: Equatable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var usageFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

public struct DeviceNetworkDisplayRate: Equatable {
    public let interfaceName: String
    public let receiveBytesPerSecond: Double
    public let transmitBytesPerSecond: Double

    public init(interfaceName: String, receiveBytesPerSecond: Double, transmitBytesPerSecond: Double) {
        self.interfaceName = interfaceName
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.transmitBytesPerSecond = transmitBytesPerSecond
    }
}

public struct DeviceDiskDisplayUsage: Equatable {
    public let mountPath: String
    public let usedBytes: UInt64
    public let totalBytes: UInt64

    public init(mountPath: String, usedBytes: UInt64, totalBytes: UInt64) {
        self.mountPath = mountPath
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var usageFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

public struct DeviceDiskIODisplayRate: Equatable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double) {
        self.readBytesPerSecond = max(readBytesPerSecond, 0)
        self.writeBytesPerSecond = max(writeBytesPerSecond, 0)
    }

    public var peakBytesPerSecond: Double {
        max(readBytesPerSecond, writeBytesPerSecond)
    }
}

public struct DeviceCPUCoreDisplayUsage: Equatable {
    public let index: Int
    public let usage: Double?

    public init(index: Int, usage: Double?) {
        self.index = max(index, 0)
        self.usage = usage.map { min(max($0, 0), 1) }
    }
}

public struct DeviceSystemDisplayInfo: Equatable {
    public static let unavailable = DeviceSystemDisplayInfo(
        hostname: "--",
        currentUser: "--",
        architecture: "--",
        operatingSystem: "--",
        uptimeText: "--",
        kernelVersion: "--",
        cpuModel: "--"
    )

    public let hostname: String
    public let currentUser: String
    public let architecture: String
    public let operatingSystem: String
    public let uptimeText: String
    public let kernelVersion: String
    public let cpuModel: String

    public init(
        hostname: String,
        currentUser: String,
        architecture: String,
        operatingSystem: String,
        uptimeText: String,
        kernelVersion: String,
        cpuModel: String
    ) {
        self.hostname = hostname
        self.currentUser = currentUser
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.uptimeText = uptimeText
        self.kernelVersion = kernelVersion
        self.cpuModel = cpuModel
    }
}

public struct DeviceMetricsDisplaySnapshot: Equatable {
    public let cpuUsage: Double?
    public let cpuCoreUsages: [DeviceCPUCoreDisplayUsage]
    public let system: DeviceSystemDisplayInfo
    public let memory: DeviceMemoryDisplayUsage
    public let networks: [DeviceNetworkDisplayRate]
    public let disks: [DeviceDiskDisplayUsage]
    public let diskIO: DeviceDiskIODisplayRate?

    public init(
        cpuUsage: Double?,
        cpuCoreUsages: [DeviceCPUCoreDisplayUsage] = [],
        system: DeviceSystemDisplayInfo = .unavailable,
        memory: DeviceMemoryDisplayUsage,
        networks: [DeviceNetworkDisplayRate],
        disks: [DeviceDiskDisplayUsage],
        diskIO: DeviceDiskIODisplayRate? = nil
    ) {
        self.cpuUsage = cpuUsage.map { min(max($0, 0), 1) }
        self.cpuCoreUsages = cpuCoreUsages
        self.system = system
        self.memory = memory
        self.networks = networks
        self.disks = disks
        self.diskIO = diskIO
    }
}

public protocol DeviceMetricsProviding: AnyObject {
    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void)
}

public final class CoreBridgeDeviceMetricsProvider: DeviceMetricsProviding {
    private let context: TunnelLiveSessionContext
    private let workerQueue = DispatchQueue(label: "Stacio.DeviceMetricsProvider", qos: .utility)
    private var previousSnapshot: DeviceMetricsSnapshot?

    public init(context: TunnelLiveSessionContext) {
        self.context = context
    }

    public func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        let previous = previousSnapshot
        workerQueue.async { [context] in
            let result = Result {
                try CoreBridge.probeLiveDeviceMetrics(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256
                )
            }

            DispatchQueue.main.async { [weak self] in
                switch result {
                case let .success(snapshot):
                    let display = DeviceMetricsDisplayFormatter.displaySnapshot(
                        current: snapshot,
                        previous: previous
                    )
                    self?.previousSnapshot = snapshot
                    completion(.success(display))
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }
}

public enum DeviceMetricsDisplayFormatter {
    public static func displaySnapshot(
        current: DeviceMetricsSnapshot,
        previous: DeviceMetricsSnapshot?
    ) -> DeviceMetricsDisplaySnapshot {
        DeviceMetricsDisplaySnapshot(
            cpuUsage: cpuUsage(current: current.cpu, previous: previous?.cpu),
            cpuCoreUsages: cpuCoreUsages(current: current.cpuCores, previous: previous?.cpuCores),
            system: systemInfo(current.system),
            memory: DeviceMemoryDisplayUsage(
                usedBytes: current.memory.totalBytes.saturatingSubtract(current.memory.availableBytes),
                totalBytes: current.memory.totalBytes
            ),
            networks: networkRates(current: current, previous: previous),
            disks: current.disks.map {
                DeviceDiskDisplayUsage(
                    mountPath: $0.mountPath,
                    usedBytes: $0.usedBytes,
                    totalBytes: $0.totalBytes
                )
            },
            diskIO: diskIORate(current: current, previous: previous)
        )
    }

    private static func systemInfo(_ system: DeviceSystemInfo) -> DeviceSystemDisplayInfo {
        DeviceSystemDisplayInfo(
            hostname: displayValue(system.hostname),
            currentUser: displayValue(system.currentUser),
            architecture: displayValue(system.architecture),
            operatingSystem: displayValue(system.operatingSystem),
            uptimeText: uptimeText(system.uptimeSeconds),
            kernelVersion: displayValue(system.kernelRelease),
            cpuModel: displayValue(system.cpuModel)
        )
    }

    private static func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "--" : trimmed
    }

    private static func uptimeText(_ seconds: UInt64?) -> String {
        guard let seconds else { return "--" }
        let days = seconds / 86_400
        if days > 0 {
            return "\(days)天"
        }
        let hours = seconds / 3_600
        if hours > 0 {
            return "\(hours)小时"
        }
        let minutes = seconds / 60
        if minutes > 0 {
            return "\(minutes)分钟"
        }
        return "<1分钟"
    }

    private static func cpuUsage(current: DeviceCpuSample, previous: DeviceCpuSample?) -> Double? {
        guard let previous else { return nil }
        let totalDelta = current.totalTicks.saturatingSubtract(previous.totalTicks)
        let idleDelta = current.idleTicks.saturatingSubtract(previous.idleTicks)
        guard totalDelta > 0 else { return nil }
        return 1 - (Double(idleDelta) / Double(totalDelta))
    }

    private static func cpuCoreUsages(
        current: [DeviceCpuSample],
        previous: [DeviceCpuSample]?
    ) -> [DeviceCPUCoreDisplayUsage] {
        current.enumerated().map { index, currentCore in
            DeviceCPUCoreDisplayUsage(
                index: index,
                usage: previous.flatMap { previousCores in
                    guard previousCores.indices.contains(index) else {
                        return nil
                    }
                    return cpuUsage(current: currentCore, previous: previousCores[index])
                }
            )
        }
    }

    private static func networkRates(
        current: DeviceMetricsSnapshot,
        previous: DeviceMetricsSnapshot?
    ) -> [DeviceNetworkDisplayRate] {
        guard let previous else {
            return current.networkInterfaces.map {
                DeviceNetworkDisplayRate(
                    interfaceName: $0.name,
                    receiveBytesPerSecond: 0,
                    transmitBytesPerSecond: 0
                )
            }
        }

        let elapsedSeconds = Double(current.sampledAtMs.saturatingSubtract(previous.sampledAtMs)) / 1_000
        guard elapsedSeconds > 0 else {
            return []
        }
        let previousByName = Dictionary(uniqueKeysWithValues: previous.networkInterfaces.map { ($0.name, $0) })
        return current.networkInterfaces.map { currentInterface in
            let previousInterface = previousByName[currentInterface.name]
            return DeviceNetworkDisplayRate(
                interfaceName: currentInterface.name,
                receiveBytesPerSecond: Double(currentInterface.receiveBytes.saturatingSubtract(previousInterface?.receiveBytes ?? currentInterface.receiveBytes)) / elapsedSeconds,
                transmitBytesPerSecond: Double(currentInterface.transmitBytes.saturatingSubtract(previousInterface?.transmitBytes ?? currentInterface.transmitBytes)) / elapsedSeconds
            )
        }
    }

    private static func diskIORate(
        current: DeviceMetricsSnapshot,
        previous: DeviceMetricsSnapshot?
    ) -> DeviceDiskIODisplayRate? {
        guard let currentDiskIO = current.diskIo else {
            return nil
        }
        guard let previous, let previousDiskIO = previous.diskIo else {
            return DeviceDiskIODisplayRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)
        }
        let elapsedSeconds = Double(current.sampledAtMs.saturatingSubtract(previous.sampledAtMs)) / 1_000
        guard elapsedSeconds > 0 else {
            return DeviceDiskIODisplayRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)
        }
        return DeviceDiskIODisplayRate(
            readBytesPerSecond: Double(currentDiskIO.readBytes.saturatingSubtract(previousDiskIO.readBytes)) / elapsedSeconds,
            writeBytesPerSecond: Double(currentDiskIO.writeBytes.saturatingSubtract(previousDiskIO.writeBytes)) / elapsedSeconds
        )
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
