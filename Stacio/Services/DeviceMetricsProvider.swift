import Foundation
import StacioCoreBindings

public struct DeviceMemoryDisplayUsage: Equatable {
    public let usedBytes: UInt64
    public let availableBytes: UInt64
    public let totalBytes: UInt64
    public let freeBytes: UInt64?
    public let buffersBytes: UInt64?
    /// Page cache plus reclaimable slab; this is not MemAvailable.
    public let cachedBytes: UInt64?
    public let swapTotalBytes: UInt64?
    public let swapFreeBytes: UInt64?

    public init(
        usedBytes: UInt64,
        totalBytes: UInt64,
        availableBytes: UInt64? = nil,
        freeBytes: UInt64? = nil,
        buffersBytes: UInt64? = nil,
        cachedBytes: UInt64? = nil,
        swapTotalBytes: UInt64? = nil,
        swapFreeBytes: UInt64? = nil
    ) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes ?? totalBytes.saturatingSubtract(usedBytes)
        self.freeBytes = freeBytes.map { min($0, totalBytes) }
        self.buffersBytes = buffersBytes.map { min($0, totalBytes) }
        self.cachedBytes = cachedBytes.map { min($0, totalBytes) }
        self.swapTotalBytes = swapTotalBytes
        self.swapFreeBytes = swapFreeBytes.map { min($0, swapTotalBytes ?? $0) }
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
    public let totalReceiveBytes: UInt64
    public let totalTransmitBytes: UInt64
    /// Direct lower interfaces from sysfs; nil means topology was unavailable.
    public let lowerInterfaceNames: [String]?

    public init(
        interfaceName: String,
        receiveBytesPerSecond: Double,
        transmitBytesPerSecond: Double,
        totalReceiveBytes: UInt64 = 0,
        totalTransmitBytes: UInt64 = 0,
        lowerInterfaceNames: [String]? = nil
    ) {
        self.interfaceName = interfaceName
        self.receiveBytesPerSecond = receiveBytesPerSecond
        self.transmitBytesPerSecond = transmitBytesPerSecond
        self.totalReceiveBytes = totalReceiveBytes
        self.totalTransmitBytes = totalTransmitBytes
        self.lowerInterfaceNames = lowerInterfaceNames
    }
}

/// Use the same automatic interface selection in both metrics presentations.
/// Virtual bridges/tunnels can account for packets already counted by the NIC.
enum DeviceMetricsNetworkSelection {
    static func automaticSelection(from networks: [DeviceNetworkDisplayRate], hideVirtual: Bool) -> [DeviceNetworkDisplayRate] {
        var seen = Set<String>()
        let networks = networks.filter { seen.insert($0.interfaceName).inserted }
        let visibleNames = Set(networks.map(\.interfaceName))
        // Count the lowest visible layer once, including custom bridge/bond
        // names. Retain a master when none of its backing interfaces is visible.
        let leaves = hideVirtual ? networks.filter { network in
            !(network.lowerInterfaceNames ?? []).contains {
                $0 != network.interfaceName && visibleNames.contains($0)
            }
        } : networks
        let preferred = hideVirtual ? leaves.filter {
            !isVirtual($0.interfaceName)
                || (isNumberedMaster($0.interfaceName.lowercased()) && $0.lowerInterfaceNames?.isEmpty == false)
        } : leaves
        let active = preferred.filter { $0.receiveBytesPerSecond > 0 || $0.transmitBytesPerSecond > 0 }
        if !active.isEmpty { return active }
        if hideVirtual, let activeMaster = leaves.first(where: {
            isNumberedMaster($0.interfaceName.lowercased()) && ($0.receiveBytesPerSecond > 0 || $0.transmitBytesPerSecond > 0)
        }) { return [activeMaster] }
        if let first = preferred.first { return [first] }
        // A host with only virtual interfaces must still have a usable reading,
        // without summing every layer of its virtual network.
        let fallback = leaves.isEmpty ? networks : leaves
        let nonLoopback = fallback.filter { $0.interfaceName.lowercased() != "lo" }
        if let active = nonLoopback.first(where: { $0.receiveBytesPerSecond > 0 || $0.transmitBytesPerSecond > 0 }) {
            return [active]
        }
        return Array((nonLoopback.isEmpty ? fallback : nonLoopback).prefix(1))
    }

    static func isVirtual(_ name: String) -> Bool {
        let name = name.lowercased()
        return name == "lo" || isNumberedMaster(name) || ["docker", "br-", "veth", "virbr", "cni", "cali", "flannel",
                               "ovn", "tun", "tap", "tailscale", "zt", "wg"].contains { name.hasPrefix($0) }
    }

    private static func isNumberedMaster(_ name: String) -> Bool {
        ["br", "vmbr", "bond"].contains { prefix in
            guard name.hasPrefix(prefix) else { return false }
            let suffix = name.dropFirst(prefix.count)
            return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
        }
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

public struct DeviceProcessDisplayInfo: Equatable {
    public let pid: UInt32
    public let name: String
    public let cpuFraction: Double
    public let memoryFraction: Double
    public let networkBytesPerSecond: Double
    public let residentBytes: UInt64?
    /// False until two compatible process counter samples are available.
    public let hasCPUUsage: Bool

    public init(pid: UInt32, name: String, cpuFraction: Double, memoryFraction: Double, networkBytesPerSecond: Double = 0, residentBytes: UInt64? = nil, hasCPUUsage: Bool = true) {
        self.pid = pid
        self.name = name
        self.cpuFraction = max(0, cpuFraction)
        self.memoryFraction = max(0, memoryFraction)
        self.networkBytesPerSecond = max(0, networkBytesPerSecond)
        self.residentBytes = residentBytes
        self.hasCPUUsage = hasCPUUsage
    }
}

/// A fraction of the host's total CPU capacity. Aggregate CPU ticks already
/// include every core. Both endpoints must refer to the same process.
public enum DeviceProcessCPUUsageCalculator {
    public static func usageFraction(
        currentTicks: UInt64?,
        previousTicks: UInt64?,
        currentStartTicks: UInt64?,
        previousStartTicks: UInt64?,
        totalTicksDelta: UInt64?,
        logicalCoreCount: Int
    ) -> Double? {
        guard let currentTicks, let previousTicks,
              let currentStartTicks, let previousStartTicks,
              let totalTicksDelta, totalTicksDelta > 0,
              logicalCoreCount > 0,
              currentStartTicks == previousStartTicks,
              currentTicks >= previousTicks else { return nil }
        let processDelta = currentTicks - previousTicks
        // Impossible intervals indicate mismatched/reset samples. Do not turn
        // invalid counters into a plausible-looking 100% by clamping them.
        guard processDelta <= totalTicksDelta else { return nil }
        return Double(processDelta) / Double(totalTicksDelta)
    }
}

public struct DevicePortDisplayInfo: Equatable {
    public let address: String
    public let protocolName: String
    public let process: String

    public init(address: String, protocolName: String, process: String) {
        self.address = address
        self.protocolName = protocolName
        self.process = process
    }
}

public struct DeviceServiceDisplayInfo: Equatable {
    public let name: String
    public let description: String
    public let state: String

    public init(name: String, description: String, state: String) {
        self.name = name
        self.description = description
        self.state = state
    }
}

public struct DeviceContainerDisplayInfo: Equatable {
    public let id: String
    public let name: String
    public let image: String
    public let status: String
    public let isRunning: Bool

    public init(id: String, name: String, image: String, status: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.image = image
        self.status = status
        self.isRunning = isRunning
    }
}

public struct DeviceSystemDisplayInfo: Equatable {
    public static let unavailable = DeviceSystemDisplayInfo(
        hostname: "--",
        currentUser: "--",
        architecture: "--",
        operatingSystem: "--",
        uptimeText: "--",
        uptimeSeconds: nil,
        kernelVersion: "--",
        cpuModel: "--"
    )

    public let hostname: String
    public let currentUser: String
    public let architecture: String
    public let operatingSystem: String
    public let uptimeText: String
    public let uptimeSeconds: UInt64?
    public let kernelVersion: String
    public let cpuModel: String

    public init(
        hostname: String,
        currentUser: String,
        architecture: String,
        operatingSystem: String,
        uptimeText: String,
        uptimeSeconds: UInt64? = nil,
        kernelVersion: String,
        cpuModel: String
    ) {
        self.hostname = hostname
        self.currentUser = currentUser
        self.architecture = architecture
        self.operatingSystem = operatingSystem
        self.uptimeText = uptimeText
        self.uptimeSeconds = uptimeSeconds
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
    public let processes: [DeviceProcessDisplayInfo]
    public let ports: [DevicePortDisplayInfo]
    public let services: [DeviceServiceDisplayInfo]
    public let containers: [DeviceContainerDisplayInfo]
    public let sshLatencyMilliseconds: Double?

    public init(
        cpuUsage: Double?,
        cpuCoreUsages: [DeviceCPUCoreDisplayUsage] = [],
        system: DeviceSystemDisplayInfo = .unavailable,
        memory: DeviceMemoryDisplayUsage,
        networks: [DeviceNetworkDisplayRate],
        disks: [DeviceDiskDisplayUsage],
        diskIO: DeviceDiskIODisplayRate? = nil,
        processes: [DeviceProcessDisplayInfo] = [],
        ports: [DevicePortDisplayInfo] = [],
        services: [DeviceServiceDisplayInfo] = [],
        containers: [DeviceContainerDisplayInfo] = [],
        sshLatencyMilliseconds: Double? = nil
    ) {
        self.cpuUsage = cpuUsage.map { min(max($0, 0), 1) }
        self.cpuCoreUsages = cpuCoreUsages
        self.system = system
        self.memory = memory
        self.networks = networks
        self.disks = disks
        self.diskIO = diskIO
        self.processes = processes
        self.ports = ports
        self.services = services
        self.containers = containers
        self.sshLatencyMilliseconds = sshLatencyMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

public protocol DeviceMetricsProviding: AnyObject {
    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void)
}

public final class CoreBridgeDeviceMetricsProvider: DeviceMetricsProviding {
    // Kept internal so the on-demand system manager can share the same
    // authenticated session without changing the metrics snapshot ABI.
    let context: TunnelLiveSessionContext
    let workerQueue = DispatchQueue(label: "Stacio.DeviceMetricsProvider", qos: .utility)
    // The controller keeps warm-up sequential, while a concurrent queue lets
    // an explicit user request bypass a currently running warm-up command.
    let inventoryWorkerQueue = DispatchQueue(label: "Stacio.DeviceMetricsInventory", qos: .utility, attributes: .concurrent)
    // Keep tab changes responsive without opening an unbounded number of SSH
    // channels when a timer refresh overlaps with a manual refresh.
    let inventoryRequestSlots = DispatchSemaphore(value: 2)
    let inventoryStateLock = NSLock()
    let inventoryProcessCPUSampler = ManagedProcessCPUSampler()
    let inventoryPortOwnershipState = ManagedPortOwnershipState()
    // Protected by inventoryStateLock; never persisted or logged.
    var inventorySudoPassword: String?
    var inventorySudoAuthorizationGeneration: UInt64 = 0
    var inventoryElevationRequired = Set<String>()
    // A rootless container store belongs to the account used to list it.
    // Never let a failed mutation silently switch subsequent reads to root.
    var inventoryContainerReadIdentity: [String: Bool] = [:]
    var inventoryContainerAuthorizationFailures: [String: DeviceMetricsInventoryError] = [:]
    var inventoryContainerAuthorizationGeneration: UInt64 = 0
    // Accessed only on workerQueue, including formatting and failure resets.
    private var previousSnapshot: DeviceMetricsSnapshot?

    public init(context: TunnelLiveSessionContext) {
        self.context = context
    }

    public func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        workerQueue.async { [self] in
            let result = Result {
                try CoreBridge.probeLiveDeviceMetrics(
                    config: context.config,
                    secret: context.secret,
                    expectedFingerprintSHA256: context.expectedFingerprintSHA256
                )
            }

            let displayResult: Result<DeviceMetricsDisplaySnapshot, Error>
            switch result {
            case let .success(snapshot):
                displayResult = .success(DeviceMetricsDisplayFormatter.displaySnapshot(
                    current: snapshot,
                    previous: previousSnapshot
                ))
                previousSnapshot = snapshot
            case let .failure(error):
                previousSnapshot = nil
                displayResult = .failure(error)
            }
            DispatchQueue.main.async {
                completion(displayResult)
            }
        }
    }
}

public enum DeviceMetricsDisplayFormatter {
    public static func displaySnapshot(
        current: DeviceMetricsSnapshot,
        previous: DeviceMetricsSnapshot?
    ) -> DeviceMetricsDisplaySnapshot {
        // Counter baselines belong to one boot. A reconnect may observe a new
        // boot whose counters already exceed those from the prior short uptime.
        let previous = previous.flatMap { sameBoot(current, $0) ? $0 : nil }
        return DeviceMetricsDisplaySnapshot(
            cpuUsage: cpuUsage(current: current.cpu, previous: previous?.cpu),
            cpuCoreUsages: cpuCoreUsages(current: current.cpuCores, previous: previous?.cpuCores),
            system: systemInfo(current.system),
            memory: DeviceMemoryDisplayUsage(
                usedBytes: current.memory.totalBytes.saturatingSubtract(current.memory.availableBytes),
                totalBytes: current.memory.totalBytes,
                availableBytes: current.memory.availableBytes,
                freeBytes: current.memory.freeBytes,
                buffersBytes: current.memory.buffersBytes,
                cachedBytes: current.memory.cachedBytes,
                swapTotalBytes: current.memory.swapTotalBytes,
                swapFreeBytes: current.memory.swapFreeBytes
            ),
            networks: networkRates(current: current, previous: previous),
            disks: current.disks.map {
                DeviceDiskDisplayUsage(
                    mountPath: $0.mountPath,
                    usedBytes: $0.usedBytes,
                    totalBytes: $0.totalBytes
                )
            },
            diskIO: diskIORate(current: current, previous: previous),
            processes: processUsages(current: current, previous: previous),
            ports: current.ports.map { DevicePortDisplayInfo(address: $0.address, protocolName: $0.protocol, process: $0.process) },
            services: current.services.map { DeviceServiceDisplayInfo(name: $0.name, description: $0.description, state: $0.state) },
            containers: current.containers.map { DeviceContainerDisplayInfo(id: $0.id, name: $0.name, image: $0.image, status: $0.status, isRunning: $0.running) },
            sshLatencyMilliseconds: current.sshLatencyMilliseconds.map(Double.init)
        )
    }

    private static func processUsages(
        current: DeviceMetricsSnapshot,
        previous: DeviceMetricsSnapshot?
    ) -> [DeviceProcessDisplayInfo] {
        let coreCount = current.cpuCores.count
        let totalTicksDelta: UInt64?
        if let previous,
           coreCount > 0, sameCoreTopology(current.cpuCores, previous.cpuCores),
           current.sampledAtMs > previous.sampledAtMs,
           current.cpu.totalTicks > previous.cpu.totalTicks,
           (current.system.uptimeSeconds ?? UInt64.max) >= (previous.system.uptimeSeconds ?? 0) {
            totalTicksDelta = current.cpu.totalTicks - previous.cpu.totalTicks
        } else {
            totalTicksDelta = nil
        }
        // Reduce safely even when a partial response accidentally repeats a PID.
        let previousByPID = (previous?.processes ?? []).reduce(into: [UInt32: DeviceProcessSample]()) {
            $0[$1.pid] = $1
        }
        return current.processes.map { process in
            let prior = previousByPID[process.pid]
            let usage = DeviceProcessCPUUsageCalculator.usageFraction(
                currentTicks: process.cpuTimeTicks,
                previousTicks: prior?.cpuTimeTicks,
                currentStartTicks: process.startTimeTicks,
                previousStartTicks: prior?.startTimeTicks,
                totalTicksDelta: totalTicksDelta,
                logicalCoreCount: coreCount
            )
            return DeviceProcessDisplayInfo(
                pid: process.pid,
                name: displayValue(process.name),
                cpuFraction: usage ?? 0,
                memoryFraction: Double(process.memoryPercentBasisPoints) / 10_000,
                networkBytesPerSecond: Double(process.networkBytesPerSecond),
                residentBytes: process.residentBytes,
                hasCPUUsage: usage != nil
            )
        }
    }

    private static func systemInfo(_ system: DeviceSystemInfo) -> DeviceSystemDisplayInfo {
        DeviceSystemDisplayInfo(
            hostname: displayValue(system.hostname),
            currentUser: displayValue(system.currentUser),
            architecture: displayValue(system.architecture),
            operatingSystem: displayValue(system.operatingSystem),
            uptimeText: uptimeText(system.uptimeSeconds),
            uptimeSeconds: system.uptimeSeconds,
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
        guard let previous, current.totalTicks > previous.totalTicks,
              current.idleTicks >= previous.idleTicks else { return nil }
        let totalDelta = current.totalTicks - previous.totalTicks
        let idleDelta = current.idleTicks - previous.idleTicks
        guard idleDelta <= totalDelta else { return nil }
        return 1 - (Double(idleDelta) / Double(totalDelta))
    }

    private static func sameCoreTopology(_ current: [DeviceCpuSample], _ previous: [DeviceCpuSample]) -> Bool {
        guard current.count == previous.count else { return false }
        let currentIDs = current.compactMap(\.coreIndex)
        let previousIDs = previous.compactMap(\.coreIndex)
        // Older snapshots lack IDs. Only retain positional compatibility when
        // neither side supplies IDs and the array sizes remain unchanged.
        if currentIDs.isEmpty && previousIDs.isEmpty { return true }
        return currentIDs.count == current.count && previousIDs.count == previous.count
            && Set(currentIDs).count == current.count && Set(previousIDs).count == previous.count
            && Set(currentIDs) == Set(previousIDs)
    }

    private static func cpuCoreUsages(
        current: [DeviceCpuSample],
        previous: [DeviceCpuSample]?
    ) -> [DeviceCPUCoreDisplayUsage] {
        if current.contains(where: { $0.coreIndex != nil }) {
            var previousByID: [UInt32: DeviceCpuSample] = [:]
            for core in previous ?? [] {
                if let id = core.coreIndex { previousByID[id] = core }
            }
            var seen = Set<UInt32>()
            return current.compactMap { core in
                guard let id = core.coreIndex, seen.insert(id).inserted else { return nil }
                return DeviceCPUCoreDisplayUsage(index: Int(id), usage: cpuUsage(current: core, previous: previousByID[id]))
            }
        }
        let compatiblePrevious = previous.flatMap {
            sameCoreTopology(current, $0) ? $0 : nil
        }
        return current.enumerated().map { index, currentCore in
            DeviceCPUCoreDisplayUsage(
                index: index,
                usage: compatiblePrevious.flatMap { previousCores in
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
        var seen = Set<String>()
        let currentInterfaces = current.networkInterfaces.filter { seen.insert($0.name).inserted }
        guard let previous else {
            return currentInterfaces.map {
                DeviceNetworkDisplayRate(
                    interfaceName: $0.name,
                    receiveBytesPerSecond: 0,
                    transmitBytesPerSecond: 0,
                    totalReceiveBytes: $0.receiveBytes,
                    totalTransmitBytes: $0.transmitBytes,
                    lowerInterfaceNames: $0.lowerInterfaceNames
                )
            }
        }

        let elapsedSeconds = counterElapsedSeconds(
            current: current, previous: previous,
            currentUptime: current.networkSampledUptimeMs,
            previousUptime: previous.networkSampledUptimeMs
        )
        // A malformed/repeated remote row must not trap the whole application.
        var previousByName: [String: DeviceNetworkSample] = [:]
        for sample in previous.networkInterfaces where previousByName[sample.name] == nil {
            previousByName[sample.name] = sample
        }
        return currentInterfaces.map { currentInterface in
            let previousInterface = previousByName[currentInterface.name]
            let rates: (Double, Double)
            if let elapsedSeconds, let previousInterface,
               currentInterface.receiveBytes >= previousInterface.receiveBytes,
               currentInterface.transmitBytes >= previousInterface.transmitBytes {
                rates = (
                    Double(currentInterface.receiveBytes - previousInterface.receiveBytes) / elapsedSeconds,
                    Double(currentInterface.transmitBytes - previousInterface.transmitBytes) / elapsedSeconds
                )
            } else { rates = (0, 0) }
            return DeviceNetworkDisplayRate(
                interfaceName: currentInterface.name,
                receiveBytesPerSecond: rates.0,
                transmitBytesPerSecond: rates.1,
                totalReceiveBytes: currentInterface.receiveBytes,
                totalTransmitBytes: currentInterface.transmitBytes,
                lowerInterfaceNames: currentInterface.lowerInterfaceNames
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
        guard let elapsedSeconds = counterElapsedSeconds(
            current: current, previous: previous,
            currentUptime: current.diskIoSampledUptimeMs,
            previousUptime: previous.diskIoSampledUptimeMs
        ), currentDiskIO.readBytes >= previousDiskIO.readBytes,
           currentDiskIO.writeBytes >= previousDiskIO.writeBytes else {
            return DeviceDiskIODisplayRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)
        }
        return DeviceDiskIODisplayRate(
            readBytesPerSecond: Double(currentDiskIO.readBytes - previousDiskIO.readBytes) / elapsedSeconds,
            writeBytesPerSecond: Double(currentDiskIO.writeBytes - previousDiskIO.writeBytes) / elapsedSeconds
        )
    }

    private static func sameBoot(_ current: DeviceMetricsSnapshot, _ previous: DeviceMetricsSnapshot) -> Bool {
        guard current.bootId == previous.bootId else { return false }
        if let now = current.system.uptimeSeconds, let before = previous.system.uptimeSeconds,
           now < before { return false }
        return true
    }

    private static func counterElapsedSeconds(
        current: DeviceMetricsSnapshot, previous: DeviceMetricsSnapshot,
        currentUptime: UInt64?, previousUptime: UInt64?
    ) -> Double? {
        guard sameBoot(current, previous) else { return nil }
        let currentTime: UInt64
        let previousTime: UInt64
        switch (currentUptime, previousUptime) {
        case let (now?, before?):
            currentTime = now
            previousTime = before
        case (nil, nil):
            // Only fully legacy records use command-completion wall time. A
            // missing clock in a modern/partially available response must not
            // silently change the timing source for one interval.
            guard !current.counterSampleClocksPresent, !previous.counterSampleClocksPresent,
                  current.bootId == nil, previous.bootId == nil,
                  current.networkSampledUptimeMs == nil, previous.networkSampledUptimeMs == nil,
                  current.diskIoSampledUptimeMs == nil, previous.diskIoSampledUptimeMs == nil else { return nil }
            currentTime = current.sampledAtMs
            previousTime = previous.sampledAtMs
        default: return nil
        }
        guard currentTime > previousTime else { return nil }
        return Double(currentTime - previousTime) / 1_000
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
