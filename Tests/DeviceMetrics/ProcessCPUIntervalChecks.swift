import Foundation

// Only the transport boundary is replaced: these checks compile the production
// provider/formatter and the actual generated core record declarations.
public struct TunnelLiveSessionContext {
    let config = "test"
    let secret = "test"
    let expectedFingerprintSHA256 = "test"
}
enum DeviceMetricsInventoryError: Error { case unavailable }
final class ManagedProcessCPUSampler {}
final class ManagedPortOwnershipState {}

enum CoreBridge {
    static let lock = NSLock()
    static var replies: [Result<DeviceMetricsSnapshot, Error>] = []

    static func probeLiveDeviceMetrics(config: String, secret: String, expectedFingerprintSHA256: String) throws -> DeviceMetricsSnapshot {
        lock.lock()
        let result = replies.removeFirst()
        lock.unlock()
        return try result.get()
    }
}

@main
enum ProcessCPUIntervalChecks {
    static var checkCount = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checkCount += 1
        precondition(condition(), message)
    }

    static func process(pid: UInt32 = 42, ticks: UInt64? = 1_000, start: UInt64? = 100,
                        lifetimeCPU: UInt32 = 60_000, memory: UInt32 = 920) -> DeviceProcessSample {
        DeviceProcessSample(pid: pid, name: "worker", cpuPercentBasisPoints: lifetimeCPU,
                            memoryPercentBasisPoints: memory, networkBytesPerSecond: 7,
                            residentBytes: 1_503_238_553, cpuTimeTicks: ticks, startTimeTicks: start)
    }

    static func snapshot(total: UInt64 = 10_000, sampledAt: UInt64 = 1_000, cores: Int = 4,
                         processes: [DeviceProcessSample]? = nil, uptime: UInt64 = 3_000) -> DeviceMetricsSnapshot {
        DeviceMetricsSnapshot(
            sampledAtMs: sampledAt,
            system: DeviceSystemInfo(hostname: "test", currentUser: "test", architecture: "x86_64",
                                     operatingSystem: "Linux", uptimeSeconds: uptime, kernelRelease: "6", cpuModel: "test"),
            cpu: DeviceCpuSample(totalTicks: total, idleTicks: total / 4),
            cpuCores: (0..<cores).map { _ in DeviceCpuSample(totalTicks: total / UInt64(max(cores, 1)), idleTicks: 0) },
            memory: DeviceMemorySample(totalBytes: 16_000_000_000, availableBytes: 8_000_000_000),
            networkInterfaces: [], diskIo: nil, disks: [], processes: processes ?? [process()]
        )
    }

    static func display(_ current: DeviceMetricsSnapshot, _ previous: DeviceMetricsSnapshot?) -> DeviceMetricsDisplaySnapshot {
        DeviceMetricsDisplayFormatter.displaySnapshot(current: current, previous: previous)
    }

    static func checkUnavailable(_ current: DeviceMetricsSnapshot, _ previous: DeviceMetricsSnapshot?, _ reason: String) {
        let result = display(current, previous).processes[0]
        check(!result.hasCPUUsage, reason)
        check(result.cpuFraction == 0, "Unavailable intervals do not leak ps lifetime CPU: \(reason)")
    }

    static func main() {
        let previous = snapshot()
        let current = snapshot(total: 11_000, sampledAt: 2_000, processes: [process(ticks: 1_535)])
        let measured = display(current, previous).processes[0]
        check(measured.hasCPUUsage, "Compatible samples have an interval")
        check(abs(measured.cpuFraction - 0.535) < 0.000_001, "Process consuming 2.14 cores on a four-core host reports 53.5%, regardless of ps lifetime CPU")
        check(measured.memoryFraction == 0.092 && measured.residentBytes == 1_503_238_553, "Memory percent and real RSS survive CPU formatting")
        check(measured.networkBytesPerSecond == 7, "Network process value is preserved")

        checkUnavailable(current, nil, "First sample needs a baseline")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, processes: [process(ticks: nil)]), previous, "Missing process ticks")
        checkUnavailable(current, snapshot(processes: [process(ticks: nil)]), "Missing baseline process ticks")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, processes: [process(start: nil)]), previous, "Missing process identity")
        checkUnavailable(current, snapshot(processes: [process(start: nil)]), "Missing baseline identity")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, processes: [process(start: 200)]), previous, "PID reuse invalidates interval")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, processes: [process(ticks: 999)]), previous, "Process counter rollback")
        checkUnavailable(snapshot(total: 9_000, sampledAt: 2_000), previous, "Aggregate counter rollback")
        checkUnavailable(snapshot(sampledAt: 2_000), previous, "Aggregate counter has no progress")
        checkUnavailable(snapshot(total: 11_000), previous, "Timestamp has no progress")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 900), previous, "Timestamp goes backwards")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, cores: 8), previous, "Core count change")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, cores: 0), snapshot(cores: 0), "Unknown core count")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, uptime: 100), previous, "Host reboot invalidates baseline")
        checkUnavailable(current, snapshot(processes: [process(pid: 99)]), "New process needs its own baseline")
        checkUnavailable(snapshot(total: 11_000, sampledAt: 2_000, processes: [process(ticks: 2_500)]), previous, "150% of host capacity is invalid and must not be clamped into a plausible value")

        let idle = display(snapshot(total: 11_000, sampledAt: 2_000), previous).processes[0]
        check(idle.hasCPUUsage && idle.cpuFraction == 0, "Measured idle is distinct from missing data")
        let full = display(snapshot(total: 11_000, sampledAt: 2_000, processes: [process(ticks: 2_000)]), previous).processes[0]
        check(full.hasCPUUsage && full.cpuFraction == 1, "Full host capacity is 100%")
        let six = display(snapshot(total: 11_000, sampledAt: 2_000, cores: 8, processes: [process(ticks: 1_750)]), snapshot(cores: 8)).processes[0]
        check(six.hasCPUUsage && six.cpuFraction == 0.75, "Six busy cores on an eight-core host report 75%")

        let almostMax = UInt64.max - 2_000
        let large = display(snapshot(total: almostMax + 1_000, sampledAt: 2_000, processes: [process(ticks: almostMax + 535)]),
                            snapshot(total: almostMax, processes: [process(ticks: almostMax)])).processes[0]
        check(abs(large.cpuFraction - 0.535) < 0.000_001, "Subtract UInt64 counters before converting to Double to retain small deltas")

        let oldProcesses = (1...150).map { process(pid: UInt32($0), ticks: 1_000, lifetimeCPU: 0) }
        let newProcesses = (1...150).map { process(pid: UInt32($0), ticks: $0 == 150 ? 1_535 : 1_000, lifetimeCPU: 0) }
        let all = display(snapshot(total: 11_000, sampledAt: 2_000, processes: newProcesses), snapshot(processes: oldProcesses)).processes
        check(all.count == 150, "All PIDs must be measured before ranking, not only lifetime leaders")
        check(all.max(by: { $0.cpuFraction < $1.cpuFraction })?.pid == 150, "New realtime leader can come from any PID")
        check(display(current, snapshot(processes: [process(), process()])).processes[0].hasCPUUsage,
              "Duplicate baseline PID cannot crash dictionary construction")

        checkQueuedProviderUsesLatestBaseline(previous: previous, current: current)
        checkFailedPollResetsBaseline(previous: previous, current: current)
        checkCoreIdentityAndHotplug()
        checkNetworkIdentityAndTopology()
        checkCounterSamplingClocks()
        checkCounterClockPresence()
        print("Process CPU interval checks passed (\(checkCount) assertions)")
    }

    static func checkCoreIdentityAndHotplug() {
        var previous = snapshot()
        previous.cpuCores = [
            .init(totalTicks: 1_000, idleTicks: 900, coreIndex: 0),
            .init(totalTicks: 2_000, idleTicks: 200, coreIndex: 1),
            .init(totalTicks: 3_000, idleTicks: 2_700, coreIndex: 2)
        ]
        var current = snapshot(total: 11_000, sampledAt: 2_000, processes: [process(ticks: 1_535)])
        current.cpuCores = [
            .init(totalTicks: 1_100, idleTicks: 990, coreIndex: 0),
            .init(totalTicks: 3_100, idleTicks: 2_790, coreIndex: 2)
        ]
        let offline = display(current, previous)
        check(offline.cpuCoreUsages.map(\.index) == [0, 2], "An offline CPU must not renumber the remaining cores")
        check(offline.cpuCoreUsages.allSatisfy { abs(($0.usage ?? -1) - 0.1) < 0.000_001 }, "Each surviving core must use its own previous counters")
        check(!offline.processes[0].hasCPUUsage, "Hotplug invalidates the process aggregate interval")
        current.cpuCores.reverse()
        let reordered = display(current, previous)
        check(reordered.cpuCoreUsages.map(\.index) == [2, 0] && reordered.cpuCoreUsages.allSatisfy { abs(($0.usage ?? -1) - 0.1) < 0.000_001 }, "Core ordering does not change identity or usage")
        current.cpuCores.append(.init(totalTicks: 10, idleTicks: 9, coreIndex: 3))
        let online = display(current, previous)
        check(online.cpuCoreUsages.last?.index == 3 && online.cpuCoreUsages.last?.usage == nil, "A newly online core needs its own baseline")
        check(!online.processes[0].hasCPUUsage, "Different core IDs invalidate process CPU even when the core count is unchanged")
        current.cpuCores.append(current.cpuCores[0])
        check(display(current, previous).cpuCoreUsages.count == 3, "A duplicate core row cannot duplicate a displayed core")

        var legacy = snapshot(total: 11_000, sampledAt: 2_000, cores: 2)
        check(display(legacy, snapshot(cores: 3)).cpuCoreUsages.allSatisfy { $0.usage == nil }, "Legacy snapshots with changed core count cannot be paired by position")
        legacy.cpu = .init(totalTicks: 11_000, idleTicks: 1)
        check(display(legacy, snapshot()).cpuUsage == nil, "Counter rollback must not produce a false 100% reading")
    }

    static func checkNetworkIdentityAndTopology() {
        var previous = snapshot()
        previous.networkInterfaces = [
            .init(name: "eth0", receiveBytes: 100, transmitBytes: 100),
            .init(name: "eth0", receiveBytes: 1_000, transmitBytes: 1_000),
            .init(name: "eth0@vlan", receiveBytes: 5, transmitBytes: 5)
        ]
        var current = snapshot(total: 11_000, sampledAt: 2_000)
        current.networkInterfaces = [
            .init(name: "eth0", receiveBytes: 200, transmitBytes: 200, lowerInterfaceNames: []),
            .init(name: "eth0", receiveBytes: 1_200, transmitBytes: 1_200),
            .init(name: "eth0@vlan", receiveBytes: 15, transmitBytes: 15, lowerInterfaceNames: ["eth0"])
        ]
        let rates = display(current, previous).networks
        check(rates.map(\.interfaceName) == ["eth0", "eth0@vlan"], "Distinct @ names survive while duplicate rows are emitted only once")
        check(rates.map(\.receiveBytesPerSecond) == [100, 10], "Duplicate rows cannot crash or corrupt the selected counter baseline")
        check(rates.last?.lowerInterfaceNames == ["eth0"] && display(current, nil).networks.last?.lowerInterfaceNames == ["eth0"], "Topology survives both first and interval samples")

        func rate(_ name: String, _ amount: Double = 100, _ lower: [String]? = nil) -> DeviceNetworkDisplayRate {
            .init(interfaceName: name, receiveBytesPerSecond: amount, transmitBytesPerSecond: amount, lowerInterfaceNames: lower)
        }
        func names(_ values: [DeviceNetworkDisplayRate], hide: Bool = true) -> [String] {
            DeviceMetricsNetworkSelection.automaticSelection(from: values, hideVirtual: hide).map(\.interfaceName)
        }
        for master in ["br0", "vmbr0", "bond0"] {
            check(names([rate("eth0"), rate(master)]) == ["eth0"], "Legacy name fallback excludes \(master) alongside its NIC")
            check(names([rate(master, 100, ["eth0"])]) == [master], "A visible \(master) remains usable when its lower interface is hidden")
            check(names([rate("eth9", 0, []), rate(master, 100, ["hidden0"])]) == [master], "An idle unrelated NIC cannot hide an active \(master)")
            check(names([rate("eth9", 20, []), rate(master, 100, ["hidden0"])]) == ["eth9", master], "Known disjoint visible lower layers both contribute")
            check(names([rate("eth9", 0), rate(master)]) == [master], "Legacy active masters remain usable alongside idle NICs")
        }
        let layered = [rate("uplink", 200, ["aggregate"]), rate("aggregate", 200, ["enp0", "enp1"]), rate("enp0", 100, []), rate("enp1", 100, [])]
        check(names(layered) == ["enp0", "enp1"], "Custom bridge/bond names use topology to count only the lowest visible layer")
        check(DeviceMetricsNetworkSelection.automaticSelection(from: layered, hideVirtual: true).reduce(0) { $0 + $1.receiveBytesPerSecond } == 200, "Layered traffic is not multiplied by bridge and bond counters")
        check(names(layered, hide: false).count == 4, "An explicit choice to show virtual interfaces remains available")
        check(names([rate("lo", 0), rate("veth0", 100), rate("docker0", 100, ["veth0"])]) == ["veth0"], "Virtual-only hosts use one visible lower interface")
        check(names([rate("eth0"), rate("eth0")]) == ["eth0"], "Duplicate display rows cannot double totals")
        check(names([rate("one", 100, ["two"]), rate("two", 100, ["one"])]).count == 1, "Malformed cyclic topology terminates with one fallback interface")
        check(names([]).isEmpty, "Empty network samples remain empty")
    }

    static func checkCounterSamplingClocks() {
        var previous = snapshot(sampledAt: 3_000, uptime: 1)
        previous.networkInterfaces = [.init(name: "eth0", receiveBytes: 1_000, transmitBytes: 2_000)]
        previous.diskIo = .init(readBytes: 1_000, writeBytes: 2_000)
        previous.networkSampledUptimeMs = 1_000
        previous.diskIoSampledUptimeMs = 1_500
        previous.bootId = "boot-a"
        var current = snapshot(total: 11_000, sampledAt: 4_000, uptime: 4)
        current.networkInterfaces = [.init(name: "eth0", receiveBytes: 4_000, transmitBytes: 8_000)]
        current.diskIo = .init(readBytes: 4_000, writeBytes: 8_000)
        current.networkSampledUptimeMs = 4_000
        current.diskIoSampledUptimeMs = 4_500
        current.bootId = "boot-a"
        func rates(_ now: DeviceMetricsSnapshot, _ before: DeviceMetricsSnapshot?) -> (Double, Double) {
            let value = display(now, before)
            return (value.networks.first?.receiveBytesPerSecond ?? -1, value.diskIO?.readBytesPerSecond ?? -1)
        }
        check(rates(current, previous) == (1_000, 1_000), "A slow prior probe tail cannot turn constant 1000 B/s traffic into a false 3000 B/s spike")
        check(display(current, previous).networks[0].transmitBytesPerSecond == 2_000
              && display(current, previous).diskIO?.writeBytesPerSecond == 2_000, "Both counter directions use remote sample time")
        var independentDisk = current
        independentDisk.diskIoSampledUptimeMs = 3_500
        check(rates(independentDisk, previous) == (1_000, 1_500), "Network topology delay is excluded by sampling disk and network clocks independently")
        var wallClockRollback = current
        wallClockRollback.sampledAtMs = 1
        check(rates(wallClockRollback, previous) == (1_000, 1_000), "Local wall-clock changes do not affect remote counter rates")
        check(rates(current, nil) == (0, 0), "A first sample establishes a baseline without reporting a spike")

        var noBootBefore = previous, noBootNow = current
        noBootBefore.bootId = nil; noBootNow.bootId = nil
        check(rates(noBootNow, noBootBefore) == (1_000, 1_000), "Restricted boot_id access still allows two remote uptime samples")
        check(rates(noBootNow, previous) == (0, 0) && rates(current, noBootBefore) == (0, 0), "Boot identity availability changes rebuild the baseline")
        var rebooted = current
        rebooted.bootId = "boot-b"
        check(rates(rebooted, previous) == (0, 0), "A known new boot is rejected even if uptime and counters exceed the old boot")
        check(display(rebooted, previous).cpuUsage == nil && !display(rebooted, previous).processes[0].hasCPUUsage,
              "A known new boot cannot reuse CPU baselines either")
        var uptimeRollback = noBootNow
        uptimeRollback.system.uptimeSeconds = 0
        check(rates(uptimeRollback, noBootBefore) == (0, 0), "Host uptime rollback invalidates baselines without a boot ID")

        for invalidTime: UInt64? in [nil, 500, 1_000] {
            var invalid = current
            invalid.networkSampledUptimeMs = invalidTime
            check(rates(invalid, previous).0 == 0 && rates(invalid, previous).1 == 1_000,
                  "Missing, rolled-back or unchanged network time cannot fall back to command-completion time or affect disk")
        }
        var noDiskBefore = previous, noDiskNow = current
        noDiskBefore.diskIoSampledUptimeMs = nil; noDiskNow.diskIoSampledUptimeMs = nil
        check(rates(noDiskNow, noDiskBefore) == (1_000, 0), "Two missing disk clocks in modern records cannot silently use wall time")
        for invalidTime: UInt64? in [nil, 500, 1_500] {
            var invalid = current
            invalid.diskIoSampledUptimeMs = invalidTime
            check(rates(invalid, previous) == (1_000, 0), "Missing, rolled-back or unchanged disk time invalidates only disk rates")
        }
        var legacyBefore = noBootBefore, legacyNow = noBootNow
        legacyBefore.networkSampledUptimeMs = nil; legacyBefore.diskIoSampledUptimeMs = nil
        legacyNow.networkSampledUptimeMs = nil; legacyNow.diskIoSampledUptimeMs = nil
        check(rates(legacyNow, legacyBefore) == (3_000, 3_000), "Two legacy payloads retain their existing wall-clock behavior")
        check(rates(noBootNow, legacyBefore) == (0, 0) && rates(legacyNow, noBootBefore) == (0, 0),
              "Transitions between remote clock and legacy wall clock never mix the two time sources")
        var reset = current
        reset.networkInterfaces[0].transmitBytes = 1
        reset.diskIo?.writeBytes = 1
        check(rates(reset, previous) == (0, 0), "Counter resets rebuild both directions instead of combining a reset and an old baseline")
        var recovered = reset
        recovered.networkSampledUptimeMs = 5_000; recovered.diskIoSampledUptimeMs = 5_500
        recovered.networkInterfaces[0].receiveBytes += 1_000; recovered.networkInterfaces[0].transmitBytes += 2_000
        recovered.diskIo?.readBytes += 1_000; recovered.diskIo?.writeBytes += 2_000
        check(rates(recovered, reset) == (1_000, 1_000), "The next valid interval recovers after a counter reset")
        var zeroBefore = previous, zeroNow = current
        zeroBefore.networkSampledUptimeMs = 0; zeroBefore.diskIoSampledUptimeMs = 0
        zeroNow.networkSampledUptimeMs = 3_000; zeroNow.diskIoSampledUptimeMs = 3_000
        check(rates(zeroNow, zeroBefore) == (1_000, 1_000), "Zero is a valid boot-relative timestamp, not a missing value")
        let nearLimit = UInt64.max - 4_000
        zeroBefore.networkSampledUptimeMs = nearLimit; zeroBefore.diskIoSampledUptimeMs = nearLimit
        zeroNow.networkSampledUptimeMs = nearLimit + 3_000; zeroNow.diskIoSampledUptimeMs = nearLimit + 3_000
        check(rates(zeroNow, zeroBefore) == (1_000, 1_000), "Large uptime counters subtract before Double conversion")
    }

    static func checkCounterClockPresence() {
        var legacyBefore = snapshot(sampledAt: 3_000, uptime: 1)
        legacyBefore.networkInterfaces = [.init(name: "eth0", receiveBytes: 1_000, transmitBytes: 2_000)]
        legacyBefore.diskIo = .init(readBytes: 1_000, writeBytes: 2_000)
        var legacyNow = snapshot(sampledAt: 4_000, uptime: 4)
        legacyNow.networkInterfaces = [.init(name: "eth0", receiveBytes: 4_000, transmitBytes: 8_000)]
        legacyNow.diskIo = .init(readBytes: 4_000, writeBytes: 8_000)
        func rates(_ value: DeviceMetricsDisplaySnapshot) -> (Double, Double) {
            (value.networks.first?.receiveBytesPerSecond ?? -1, value.diskIO?.readBytesPerSecond ?? -1)
        }
        check(!legacyBefore.counterSampleClocksPresent && !legacyNow.counterSampleClocksPresent,
              "Old snapshot initializers keep clock-presence false by default")
        check(rates(display(legacyNow, legacyBefore)) == (3_000, 3_000), "Genuinely legacy records retain wall-clock fallback")
        var unavailableBefore = legacyBefore, unavailableNow = legacyNow
        unavailableBefore.counterSampleClocksPresent = true
        unavailableNow.counterSampleClocksPresent = true
        check(unavailableNow.networkSampledUptimeMs == nil && unavailableNow.diskIoSampledUptimeMs == nil && unavailableNow.bootId == nil,
              "The modern unreadable-procfs fixture has all three optional measurements missing")
        let missing = display(unavailableNow, unavailableBefore)
        check(rates(missing) == (0, 0), "Two modern responses with unavailable clocks cannot recreate the false 3000 B/s wall-clock spike")
        check(missing.networks[0].transmitBytesPerSecond == 0 && missing.diskIO?.writeBytesPerSecond == 0,
              "Unavailable modern clocks suppress both transmit/write directions too")
        check(rates(display(unavailableNow, legacyBefore)) == (0, 0)
              && rates(display(legacyNow, unavailableBefore)) == (0, 0),
              "New/legacy transitions cannot use wall time even when both sides lack all optional measurements")
        check(missing.networks[0].totalReceiveBytes == 4_000 && missing.networks[0].totalTransmitBytes == 8_000,
              "Unavailable interval timing does not discard valid cumulative counters")

        var restored = unavailableNow
        restored.sampledAtMs = 5_000
        restored.system.uptimeSeconds = 5
        restored.networkSampledUptimeMs = 5_000
        restored.diskIoSampledUptimeMs = 5_500
        restored.networkInterfaces[0].receiveBytes = 5_000
        restored.networkInterfaces[0].transmitBytes = 10_000
        restored.diskIo = .init(readBytes: 5_000, writeBytes: 10_000)
        var next = restored
        next.sampledAtMs = 5_001 // Completion timing is deliberately unlike the remote interval.
        next.system.uptimeSeconds = 6
        next.networkSampledUptimeMs = 6_000
        next.diskIoSampledUptimeMs = 6_500
        next.networkInterfaces[0].receiveBytes = 6_000
        next.networkInterfaces[0].transmitBytes = 12_000
        next.diskIo = .init(readBytes: 6_000, writeBytes: 12_000)
        let sequence = collect([.success(unavailableBefore), .success(unavailableNow), .success(restored), .success(next)])
        let snapshots = sequence.map { try! $0.get() }
        check(snapshots.prefix(3).allSatisfy { rates($0) == (0, 0) },
              "Missing modern clocks and their first restored sample only establish a baseline")
        check(rates(snapshots[3]) == (1_000, 1_000), "The provider recovers on the next valid remote-clock interval without a wall-clock spike")
        check(snapshots[3].networks[0].transmitBytesPerSecond == 2_000 && snapshots[3].diskIO?.writeBytesPerSecond == 2_000,
              "Transmit/write rates recover from the same correct baseline")
        var networkOnly = restored
        networkOnly.diskIoSampledUptimeMs = nil
        check(rates(display(next, networkOnly)) == (1_000, 0), "Restoring only one modern clock does not silently enable the other category's wall-clock fallback")
    }

    static func collect(_ replies: [Result<DeviceMetricsSnapshot, Error>]) -> [Result<DeviceMetricsDisplaySnapshot, Error>] {
        CoreBridge.lock.lock()
        CoreBridge.replies = replies
        CoreBridge.lock.unlock()
        let provider = CoreBridgeDeviceMetricsProvider(context: TunnelLiveSessionContext())
        var results: [Result<DeviceMetricsDisplaySnapshot, Error>] = []
        // Queue every request before yielding to the main queue. Capturing the
        // baseline in pollDeviceMetrics would give all requests a nil baseline.
        for _ in replies {
            provider.pollDeviceMetrics { result in
                check(Thread.isMainThread, "Provider completion remains on main thread")
                results.append(result)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while results.count < replies.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        check(results.count == replies.count, "All queued polls finish")
        return results
    }

    static func checkQueuedProviderUsesLatestBaseline(previous: DeviceMetricsSnapshot, current: DeviceMetricsSnapshot) {
        let results = collect([.success(previous), .success(current)])
        check(try! !results[0].get().processes[0].hasCPUUsage, "First queued poll is warming up")
        check(abs(try! results[1].get().processes[0].cpuFraction - 0.535) < 0.000_001,
              "Second queued poll uses immediately preceding successful counters")
    }

    static func checkFailedPollResetsBaseline(previous: DeviceMetricsSnapshot, current: DeviceMetricsSnapshot) {
        let next = snapshot(total: 12_000, sampledAt: 3_000, processes: [process(ticks: 2_070)])
        let results = collect([.success(previous), .failure(DeviceMetricsInventoryError.unavailable), .success(current), .success(next)])
        if case .failure = results[1] { check(true, "Transport error propagated") }
        else { check(false, "Transport error propagated") }
        check(try! !results[2].get().processes[0].hasCPUUsage, "Recovery poll starts a fresh interval after transport failure")
        check(abs(try! results[3].get().processes[0].cpuFraction - 0.535) < 0.000_001,
              "Next compatible recovery sample reports realtime CPU again")
    }
}
