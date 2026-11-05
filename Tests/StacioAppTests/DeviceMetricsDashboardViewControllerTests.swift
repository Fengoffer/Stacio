import AppKit
import ObjectiveC
import XCTest
@testable import StacioApp
import StacioCoreBindings

@MainActor
final class DeviceMetricsDashboardViewControllerTests: XCTestCase {
    func testInventoryProcessMetaRowKeepsCountAndSortColumnsReadableAtNarrowWidth() {
        let panel = DeviceMetricsInventoryPanel(segment: 1)
        panel.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
        panel.layoutSubtreeIfNeeded()

        XCTAssertEqual(panel.sortControl.segmentCount, 5)
        XCTAssertEqual(panel.countLabel.contentHuggingPriority(for: .horizontal), .required)
        XCTAssertEqual(panel.countLabel.contentCompressionResistancePriority(for: .horizontal), .required)
        XCTAssertGreaterThanOrEqual(panel.countLabel.frame.width, 64)
        XCTAssertGreaterThan(panel.sortControl.frame.width, 0)
        XCTAssertGreaterThanOrEqual(panel.sortControl.frame.minX, -0.5)
        XCTAssertLessThanOrEqual(panel.sortControl.frame.maxX, panel.bounds.width + 0.5)
    }
    func testDashboardNavigationStaysAboveScrollContentAndSwitchesWholeBody() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "navigation", title: "test-host",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample), startsPollingAutomatically: false
        )
        controller.loadView()
        let root = controller.view
        let tabs = try XCTUnwrap(root.firstSubview(withIdentifier: "Stacio.Metrics.inventoryTabs") as? NSSegmentedControl)
        let scroll = try XCTUnwrap(root.firstSubview(withIdentifier: "Stacio.Metrics.scrollView") as? NSScrollView)
        XCTAssertFalse(tabs.isDescendant(of: scroll))
        XCTAssertNotNil(root.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU"), "Overview must exist before the first sample")
        controller.refreshMetricsForTesting()
        let historyCount = controller.historySamplesForTesting(metric: .cpuUsage).count
        for (segment, identifier) in [(1, "processList"), (2, "portList"), (3, "serviceList"), (4, "containerList")] {
            tabs.selectedSegment = segment
            tabs.sendAction(tabs.action, to: tabs.target)
            XCTAssertNotNil(root.firstSubview(withIdentifier: "Stacio.Metrics.\(identifier)"))
            XCTAssertNil(root.firstSubview(withIdentifier: "Stacio.Metrics.section.system"))
            XCTAssertNil(root.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU"))
            XCTAssertNil(root.firstSubview(withIdentifier: "Stacio.Metrics.section.network"))
            XCTAssertNil(root.firstSubview(withIdentifier: "Stacio.Metrics.section.disks"))
        }
        tabs.selectedSegment = 0
        tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertNotNil(root.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU"))
        XCTAssertNil(root.firstSubview(withIdentifier: "Stacio.Metrics.containerList"))
        XCTAssertEqual(controller.historySamplesForTesting(metric: .cpuUsage).count, historyCount)
    }

    func testDashboardPollingAndTabSwitchesPreserveOverviewControlsAndColors() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "navigation_refresh", title: "test-host",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample), startsPollingAutomatically: false
        )
        controller.loadView()
        controller.refreshMetricsForTesting()
        let root = controller.view
        let cpuTile = try XCTUnwrap(root.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU"))
        let cpuValue = try XCTUnwrap(cpuTile.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "42%" })
        let color = cpuValue.textColor
        let tabs = try XCTUnwrap(root.firstSubview(withIdentifier: "Stacio.Metrics.inventoryTabs") as? NSSegmentedControl)
        for _ in 0..<3 {
            controller.refreshMetricsForTesting()
            XCTAssertTrue(root.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU") === cpuTile)
            tabs.selectedSegment = 1
            tabs.sendAction(tabs.action, to: tabs.target)
            controller.refreshMetricsForTesting()
            XCTAssertEqual(tabs.selectedSegment, 1)
            XCTAssertNil(root.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU"))
            tabs.selectedSegment = 0
            tabs.sendAction(tabs.action, to: tabs.target)
            XCTAssertTrue(root.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU") === cpuTile)
            XCTAssertEqual(cpuValue.textColor, color)
            XCTAssertEqual(cpuValue.stringValue, "42%")
        }
        XCTAssertEqual(controller.historySamplesForTesting(metric: .cpuUsage).count, 7)
    }

    func testDashboardTabSelectionInvalidatesHeightAndResetsScrollPosition() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "navigation_height", title: "test-host",
            provider: RecordingDeviceMetricsProvider(snapshot: .dense), startsPollingAutomatically: false
        )
        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 360)
        controller.view.layoutSubtreeIfNeeded()
        let root = controller.view
        let tabs = try XCTUnwrap(root.firstSubview(withIdentifier: "Stacio.Metrics.inventoryTabs") as? NSSegmentedControl)
        let scroll = try XCTUnwrap(root.firstSubview(withIdentifier: "Stacio.Metrics.scrollView") as? NSScrollView)
        let overviewHeight = controller.preferredFloatingHeight(width: 360)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        var layoutNotifications = 0
        controller.metricsDidUpdate = { layoutNotifications += 1 }
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertEqual(layoutNotifications, 1)
        XCTAssertLessThan(controller.preferredFloatingHeight(width: 360), overviewHeight)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    }

    func testMetricValueFormatterUsesAdaptiveBinaryUnitsForRatesAndMemory() {
        XCTAssertEqual(DeviceMetricValueFormatter.bytesPerSecond(512), "512 B/s")
        XCTAssertEqual(DeviceMetricValueFormatter.bytesPerSecond(1_536), "1.5 KB/s")
        XCTAssertEqual(DeviceMetricValueFormatter.bytesPerSecond(2 * 1_048_576), "2.0 MB/s")
        XCTAssertEqual(DeviceMetricValueFormatter.bytesPerSecond(3 * 1_073_741_824), "3.0 GB/s")
        XCTAssertEqual(DeviceMetricValueFormatter.bytes(5 * 1_073_741_824), "5.0 GB")
    }

    func testInventoryProcessParserPreservesFullManagementFields() {
        let processes = DeviceMetricsInventoryParser.processes(
            "  412     1 deploy Ssl 12.5 3.1 4096 16384 02:14:31 /usr/local/bin/worker --serve api"
        )

        let process = try? XCTUnwrap(processes.first)
        XCTAssertEqual(process?.pid, 412)
        XCTAssertEqual(process?.parentPID, 1)
        XCTAssertEqual(process?.user, "deploy")
        XCTAssertEqual(process?.state, "Ssl")
        XCTAssertEqual(process?.cpuPercent, 12.5)
        XCTAssertEqual(process?.memoryPercent, 3.1)
        XCTAssertEqual(process?.residentBytes, 4_194_304)
        XCTAssertEqual(process?.virtualBytes, 16_777_216)
        XCTAssertEqual(process?.elapsed, "02:14:31")
        XCTAssertEqual(process?.command, "/usr/local/bin/worker --serve api")
        XCTAssertFalse(process?.isRunning == true)
        XCTAssertEqual(process?.statusLabel, "睡眠")
    }

    func testInventoryProcessParserHandlesBusyBoxTopCPUColumn() throws {
        let processes = DeviceMetricsInventoryParser.processes("""
        PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND
        1 0 root S 1356 1% 0 2% /sbin/procd
        411 1 root R 97.6m 10.0 3 7.0 /sbin/ubusd --foreground
        """)

        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].cpuPercent, 2)
        XCTAssertEqual(processes[0].memoryPercent, 0)
        XCTAssertFalse(processes[0].hasMemoryUsage)
        XCTAssertEqual(processes[0].command, "/sbin/procd")
        XCTAssertEqual(processes[1].cpuPercent, 7)
        XCTAssertEqual(processes[1].command, "/sbin/ubusd --foreground")
    }

    func testInventoryProcessParserMapsOptionalBusyBoxCPUColumns() {
        for (header, row, expectedCPU) in [
            ("PID PPID USER STAT VSZ %VSZ CPU COMMAND", "21 1 root S 1356 1% 7 123 --worker", nil),
            ("PID PPID USER STAT VSZ %VSZ COMMAND", "21 1 root S 1356 1% 123 --worker", nil),
            ("PID PPID USER STAT VSZ %VSZ %CPU COMMAND", "21 1 root S 1356 1% 2.5 123 --worker", 2.5),
            ("PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND", "21 1 root S 1356 1% 7 2.5 123 --worker", 2.5)
        ] as [(String, String, Double?)] {
            let values = DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_TOP__\n" + header + "\n" + row)
            XCTAssertEqual(values.count, 1)
            XCTAssertEqual(values.first?.command, "123 --worker")
            XCTAssertEqual(values.first?.hasCPUUsage, expectedCPU != nil)
            XCTAssertEqual(values.first?.cpuPercent, expectedCPU ?? 0)
            XCTAssertEqual(values.first?.memoryPercent, 0)
            XCTAssertEqual(values.first?.hasMemoryUsage, false)
            XCTAssertEqual(values.first?.virtualBytes, 1_388_544)
        }
        XCTAssertTrue(DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_TOP__\nPID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND\n21 1 root S 1356 1% 7 nan worker").isEmpty)
    }

    func testInventoryBusyBoxMemoryUsageRequiresVerifiedResidentMemory() throws {
        let top = """
        __STACIO_PROCESS_TOP__
        PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND
        21 1 root S 8192 80% 0 2% worker
        """
        for (afterStart, rss, totalKB, expectedPercent) in [
            ("42", "256", "1024", 25.0),
            ("43", "256", "1024", nil), // PID reused during collection.
            ("42", "-", "1024", nil), // RSS unavailable.
            ("42", "256", "0", nil) // Physical memory unavailable.
        ] as [(String, String, String, Double?)] {
            let output = """
            __STACIO_IDENTITIES_BEFORE__
            boot 1000 \(totalKB)
            21 42 128
            __STACIO_IDENTITIES_END__
            \(top)
            __STACIO_IDENTITIES_AFTER__
            boot 1000 \(totalKB)
            21 \(afterStart) \(rss)
            __STACIO_IDENTITIES_END__
            """
            let process = try XCTUnwrap(DeviceMetricsInventoryParser.processes(output).first)
            XCTAssertEqual(process.hasMemoryUsage, expectedPercent != nil)
            XCTAssertEqual(process.memoryPercent, expectedPercent ?? 0)
            XCTAssertEqual(process.residentBytes, expectedPercent == nil ? 0 : 256 * 1024)
            XCTAssertEqual(process.virtualBytes, 8192 * 1024)
        }
    }

    func testInventoryProcessCPUOrderingKeepsUnavailableValuesLast() {
        let panel = DeviceMetricsInventoryPanel(segment: 1)
        panel.update([
            .init(id: "unknown", title: "unknown", subtitle: "", badge: "睡眠", tone: .normal, filter: 0, search: "unknown", cpu: 999, hasCPUUsage: false, pid: 1),
            .init(id: "idle", title: "idle", subtitle: "", badge: "睡眠", tone: .normal, filter: 0, search: "idle", cpu: 0, pid: 2),
            .init(id: "busy", title: "busy", subtitle: "", badge: "运行中", tone: .success, filter: 1, search: "busy", cpu: 7, pid: 3)
        ])
        XCTAssertEqual(panel.visibleRows.map(\.id), ["busy", "idle", "unknown"])
        panel.sortControl.sendAction(panel.sortControl.action, to: panel.sortControl.target)
        XCTAssertEqual(panel.visibleRows.map(\.id), ["idle", "busy", "unknown"])
    }

    func testInventoryProcessParserHandlesPaddedBusyBoxTopAndLongPSCommands() {
        let top = DeviceMetricsInventoryParser.processes("""
          PID  PPID USER     STAT   VSZ %VSZ CPU %CPU COMMAND
            1     0 root     S       1356   1%   0   2% /sbin/procd
          411     1 root     R     97.6m 10.0   3  7.0 /sbin/ubusd --foreground
          PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
           21     1 root     S       2048  0.5  2.5 /usr/sbin/daemon --foreground
        """)
        XCTAssertEqual(top.map(\.cpuPercent), [2, 7, 2.5])
        XCTAssertEqual(top.map(\.state), ["S", "R", "S"])
        XCTAssertEqual(top.last?.command, "/usr/sbin/daemon --foreground")

        let command = "/bin/sh -c worker --one a --two b --three c --four d"
        let ps = DeviceMetricsInventoryParser.processes(" 22 root 4096 S " + command + "\n 23 S 01:20 " + command)
        XCTAssertEqual(ps.map(\.command), [command, command])
        XCTAssertEqual(ps.first?.virtualBytes, 4_194_304)
        XCTAssertEqual(ps.last?.elapsed, "01:20")
        XCTAssertTrue(DeviceMetricsInventoryParser.processes("15 1 1000 S nan 2 1 1 00:01 invalid\n16 1 root S 2 nan 1 1 00:01 invalid\n17 not-a-state 00:01 invalid").isEmpty)
    }

    func testInventoryCollectorFallsBackWhenPSIgnoresFormatOptions() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-xctest-process-handshake-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let ps = fixture.appendingPathComponent("ps")
        // This is BusyBox's no-option build: every argv is ignored, no header
        // is printed, and the otherwise successful ps always uses short rows.
        try "#!/bin/sh\nprintf '%s\\n' '21 1000 4096 S ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4'\n".write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
        for hasTop in [true, false] {
            let top = fixture.appendingPathComponent("top")
            let script = hasTop
                ? "#!/bin/sh\nprintf '%s\\n' 'PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND' '22 1 root R 4096 1% 7 9.5 /sbin/worker'\n"
                : "#!/bin/sh\nexit 44\n"
            try script.write(to: top, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: top.path)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", DeviceMetricsInventoryCommands.processes]
            process.environment = ["PATH": fixture.path + ":/usr/bin:/bin", "TMPDIR": fixture.path]
            process.standardOutput = output
            try process.run()
            let raw = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertFalse(raw.contains("__STACIO_PROCESS_FULL_PS__"))
            let values = DeviceMetricsInventoryParser.processes(raw)
            XCTAssertEqual(values.map(\.pid), [hasTop ? 22 : 21])
            XCTAssertEqual(values.first?.hasCPUUsage, hasTop)
            if hasTop {
                XCTAssertEqual(values.first?.cpuPercent, 9.5)
            } else {
                XCTAssertEqual(values.first?.user, "1000")
                XCTAssertEqual(values.first?.command, "ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4")
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
            XCTAssertFalse(leftovers.contains { $0.hasPrefix("stacio-processes.") })
        }
    }

    func testInventoryFullPSHeaderDoesNotWeakenNumericValidation() {
        let header = "__STACIO_PROCESS_FULL_PS__\n    __STACIO_PROCESS_PID__     \n"
        let values = DeviceMetricsInventoryParser.processes(header + "23 1 1000 S 12.5 2.5 4096 8192 00:01 ffmpeg -i input.mp4 -ss 00:10")
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.cpuPercent, 12.5)
        XCTAssertEqual(values.first?.residentBytes, 4_194_304)
        XCTAssertEqual(values.first?.command, "ffmpeg -i input.mp4 -ss 00:10")
        XCTAssertTrue(DeviceMetricsInventoryParser.processes(header + "23 1 1000 S nan 2 1 1 00:01 invalid").isEmpty)
    }

    func testInventoryProcessParserUsesSourceForNumericBusyBoxUsers() {
        let command = "ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4"
        for prefix in ["", "PID USER VSZ STAT COMMAND\n", "__STACIO_PROCESS_PS__\nPID USER VSZ STAT COMMAND\n"] {
            let processes = DeviceMetricsInventoryParser.processes(prefix + "22 1000 4096 S " + command)
            XCTAssertEqual(processes.count, 1)
            XCTAssertEqual(processes.first?.user, "1000")
            XCTAssertEqual(processes.first?.virtualBytes, 4_194_304)
            XCTAssertEqual(processes.first?.command, command)
        }
        let ambiguous = "15 1 1000 S nan 2 1 1 00:01 invalid"
        XCTAssertTrue(DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_FULL_PS__\n" + ambiguous).isEmpty)
        XCTAssertEqual(DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_PS__\nPID USER VSZ STAT COMMAND\n" + ambiguous).first?.command, "nan 2 1 1 00:01 invalid")
        XCTAssertEqual(DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_FULL_PS__\n12 1 root S 1 2 3 4 00:01 partial\n__STACIO_PROCESS_PS__\nPID USER VSZ STAT COMMAND\n22 1000 4096 S " + command).map(\.pid), [22])
    }

    func testInventoryPortParserExcludesConnectedUDPAndTCPClients() {
        let ports = DeviceMetricsInventoryParser.ports("""
        udp4 0 0 192.168.1.2.54321 1.1.1.1.53 196724 9216
        udp6 0 0 fe80::1.54322 fe80::2.53 196724 9216
        udp ESTAB 0 0 192.168.1.2:54323 1.1.1.1:53 users:(("dns",pid=3,fd=4),("dns-worker",pid=4,fd=5))
        udp UNCONN 0 0 192.168.1.2:54324 1.1.1.1:53 users:(("dns",pid=3,fd=4),("dns-worker",pid=4,fd=5))
        udp4 0 0 *.53 *.* 196724 9216
        udp6 0 0 *.5353 *.* 196724 9216
        udp 0 0 127.0.0.1:123 0.0.0.0:* 42/ntpd
        udp UNCONN 0 0 [::]:111 [::]:* users:(("rpc",pid=11,fd=3),("rpc-worker",pid=12,fd=4))
        tcp 0 0 192.168.1.2:54325 1.1.1.1:443 ESTABLISHED 3/client
        tcp CLOSE-WAIT 0 0 192.168.1.2:54326 1.1.1.1:443 users:(("client",pid=3,fd=4),("client-worker",pid=4,fd=5))
        """)
        XCTAssertEqual(ports.count, 5)
        XCTAssertTrue(ports.allSatisfy { $0.port < 10_000 })
        XCTAssertEqual(ports.filter { $0.port == 111 }.compactMap(\.pid).sorted(), [11, 12])
        XCTAssertTrue(ports.contains { $0.protocolName == "UDP6" && $0.port == 5353 })
    }

    func testInventoryProcessParserRejectsOutOfRangeSizesWithoutTrapping() {
        XCTAssertTrue(DeviceMetricsInventoryParser.processes("""
        12 1 root S 1 2 18446744073709551615 8192 00:01 worker
        13 1 root S 1 2 8192 18446744073709551616 00:01 worker
        14 root 18446744073709551615 S worker
        15 1 root S 18446744073709551616 1 2 worker
        16 root 1e309 S worker
        """).isEmpty)
    }

    func testInventoryPortParserPreservesFamilyForAllOwnersAndMergesCollectors() {
        let ports = DeviceMetricsInventoryParser.ports("""
        __STACIO_SS__
        __STACIO_IPV4__
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("java",pid=99,fd=6))
        __STACIO_IPV6__
        tcp LISTEN 0 128 *:8080 *:* users:(("java",pid=99,fd=7),("worker",pid=100,fd=8))
        udp UNCONN 0 0 *:5353 *:* users:(("java",pid=99,fd=9),("worker",pid=100,fd=10))
        __STACIO_NETSTAT__
        tcp6 0 0 :::8080 :::* LISTEN 99/java
        tcp4 0 0 0.0.0.0:8080 0.0.0.0:* LISTEN 99/java
        tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN
        __STACIO_LSOF__
        java 99 root 7u IPv6 0x1 0t0 TCP *:8080 (LISTEN)
        worker 100 root 8u IPv6 0x2 0t0 TCP *:8080 (LISTEN)
        __STACIO_SS__
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*
        __STACIO_IPV6__
        tcp LISTEN 0 128 *:8080 *:*
        """)
        XCTAssertEqual(ports.count, 6)
        XCTAssertEqual(ports.filter { $0.protocolName == "TCP6" }.compactMap(\.pid).sorted(), [99, 100])
        XCTAssertEqual(ports.filter { $0.protocolName == "UDP6" }.compactMap(\.pid).sorted(), [99, 100])
        XCTAssertEqual(ports.first { $0.port == 443 }?.protocolName, "TCP")
        XCTAssertEqual(ports.filter { $0.port == 8080 && $0.protocolName == "TCP" }.count, 1)
    }

    func testInventoryParsersKeepPortProcessServiceAndContainerActionsAddressable() throws {
        let port = try XCTUnwrap(DeviceMetricsInventoryParser.ports(
            "tcp LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:((\"api\",pid=889,fd=7))"
        ).first)
        XCTAssertEqual(port.address, "127.0.0.1")
        XCTAssertEqual(port.port, 8080)
        XCTAssertEqual(port.processName, "api")
        XCTAssertEqual(port.pid, 889)

        let service = try XCTUnwrap(DeviceMetricsInventoryParser.services(
            "api.service loaded active running API worker service"
        ).first)
        XCTAssertEqual(service.name, "api.service")
        XCTAssertEqual(service.activeState, "active")
        XCTAssertEqual(service.subState, "running")
        XCTAssertEqual(service.description, "API worker service")

        let container = try XCTUnwrap(DeviceMetricsInventoryParser.containers(
            "8a95c6\tapi\texample/api:latest\tUp 4 minutes (Paused)"
        ).first)
        XCTAssertEqual(container.name, "api")
        XCTAssertFalse(container.isRunning)
        XCTAssertTrue(container.isPaused)
    }

    func testDisplayFormatterDerivesDiskReadWriteRateFromSnapshotCounters() throws {
        let previous = DeviceMetricsSnapshot(
            sampledAtMs: 1_000,
            system: DeviceSystemInfo(
                hostname: "worker-01",
                currentUser: "deploy",
                architecture: "x86_64",
                operatingSystem: "Ubuntu 25.10",
                uptimeSeconds: 1_210_200,
                kernelRelease: "6.8.0-64-generic",
                cpuModel: "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"
            ),
            cpu: DeviceCpuSample(totalTicks: 100, idleTicks: 80),
            cpuCores: [
                DeviceCpuSample(totalTicks: 100, idleTicks: 80),
                DeviceCpuSample(totalTicks: 100, idleTicks: 50)
            ],
            memory: DeviceMemorySample(totalBytes: 1_000, availableBytes: 600),
            networkInterfaces: [
                DeviceNetworkSample(name: "ens160", receiveBytes: 10_000, transmitBytes: 20_000)
            ],
            diskIo: DeviceDiskIoSample(readBytes: 1_000, writeBytes: 2_000),
            disks: []
        )
        let current = DeviceMetricsSnapshot(
            sampledAtMs: 3_000,
            system: DeviceSystemInfo(
                hostname: "worker-01",
                currentUser: "deploy",
                architecture: "x86_64",
                operatingSystem: "Ubuntu 25.10",
                uptimeSeconds: 1_210_200,
                kernelRelease: "6.8.0-64-generic",
                cpuModel: "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"
            ),
            cpu: DeviceCpuSample(totalTicks: 200, idleTicks: 120),
            cpuCores: [
                DeviceCpuSample(totalTicks: 200, idleTicks: 140),
                DeviceCpuSample(totalTicks: 200, idleTicks: 60)
            ],
            memory: DeviceMemorySample(totalBytes: 1_000, availableBytes: 500),
            networkInterfaces: [
                DeviceNetworkSample(name: "ens160", receiveBytes: 18_192, transmitBytes: 28_192)
            ],
            diskIo: DeviceDiskIoSample(readBytes: 5_096, writeBytes: 10_192),
            disks: [],
            processes: [
                DeviceProcessSample(pid: 42, name: "worker", cpuPercentBasisPoints: 1250, memoryPercentBasisPoints: 340, networkBytesPerSecond: 2048)
            ],
            ports: [DevicePortSample(address: "0.0.0.0:22", protocol: "tcp", process: "sshd")],
            services: [DeviceServiceSample(name: "sshd.service", description: "OpenSSH", state: "active")],
            containers: [DeviceContainerSample(id: "abc", name: "web", image: "nginx", status: "Up", running: true)]
        )

        let display = DeviceMetricsDisplayFormatter.displaySnapshot(current: current, previous: previous)

        XCTAssertEqual(display.system.hostname, "worker-01")
        XCTAssertEqual(display.system.currentUser, "deploy")
        XCTAssertEqual(display.system.architecture, "x86_64")
        XCTAssertEqual(display.system.operatingSystem, "Ubuntu 25.10")
        XCTAssertEqual(display.system.uptimeText, "14天")
        XCTAssertEqual(display.system.uptimeSeconds, 1_210_200)
        XCTAssertEqual(display.system.kernelVersion, "6.8.0-64-generic")
        XCTAssertEqual(display.system.cpuModel, "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz")
        XCTAssertEqual(display.memory.availableBytes, 500)
        let network = try XCTUnwrap(display.networks.first)
        XCTAssertEqual(network.receiveBytesPerSecond, 4_096, accuracy: 0.001)
        XCTAssertEqual(network.transmitBytesPerSecond, 4_096, accuracy: 0.001)
        XCTAssertEqual(network.totalReceiveBytes, 18_192)
        XCTAssertEqual(network.totalTransmitBytes, 28_192)
        XCTAssertEqual(display.cpuCoreUsages.count, 2)
        XCTAssertEqual(display.cpuCoreUsages[0].usage ?? -1, 0.40, accuracy: 0.001)
        XCTAssertEqual(display.cpuCoreUsages[1].usage ?? -1, 0.90, accuracy: 0.001)
        let diskIO = try XCTUnwrap(display.diskIO)
        XCTAssertEqual(diskIO.readBytesPerSecond, 2_048, accuracy: 0.001)
        XCTAssertEqual(diskIO.writeBytesPerSecond, 4_096, accuracy: 0.001)
        XCTAssertEqual(display.processes.first?.name, "worker")
        XCTAssertEqual(display.processes.first?.cpuFraction ?? -1, 0, accuracy: 0.001)
        XCTAssertFalse(display.processes.first?.hasCPUUsage ?? true, "Lifetime ps CPU is not a realtime interval")
        XCTAssertEqual(display.processes.first?.networkBytesPerSecond ?? -1, 2048, accuracy: 0.001)
        XCTAssertEqual(display.ports.first?.address, "0.0.0.0:22")
        XCTAssertEqual(display.services.first?.state, "active")
        XCTAssertTrue(display.containers.first?.isRunning == true)
    }

    func testDashboardBlankAreaOwnsMouseDragAboveTerminal() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_pointer_shield",
            title: "root@pointer-shield",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 420, y: 80, width: 300, height: 500)

        let container = DeviceMetricsForcedHitContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 640)
        )
        let terminal = StacioLocalTerminalView(frame: container.bounds)
        container.addSubview(terminal)
        container.addSubview(controller.view)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        controller.view.layoutSubtreeIfNeeded()

        let blankPoint = controller.view.convert(NSPoint(x: 5, y: 250), to: nil)
        let draggedPoint = controller.view.convert(NSPoint(x: 40, y: 280), to: nil)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: blankPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let mouseDragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: draggedPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))

        window.sendEvent(mouseDown)
        window.sendEvent(mouseDragged)

        let hit = try XCTUnwrap(container.hitTest(container.convert(blankPoint, from: nil)))
        XCTAssertFalse(hit === terminal || hit.isDescendant(of: terminal))

        container.forcedHit = terminal
        XCTAssertNil(TerminalLinkInteraction.handleEvent(in: terminal, event: mouseDown))
        XCTAssertNil(TerminalLinkInteraction.handleEvent(in: terminal, event: mouseDragged))
        container.forcedHit = nil

        let terminalMouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 120, y: 120),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        ))
        XCTAssertNotNil(TerminalLinkInteraction.handleEvent(in: terminal, event: terminalMouseDown))
    }

    func testInspectorDoesNotExposeDeviceMetricsDashboardSection() throws {
        let inspector = InspectorViewController()

        inspector.loadView()

        XCTAssertEqual(inspector.sectionLabelsForTesting, ["文件", "隧道", "浏览器", "诊断", "宏", "历史命令", "AI"])
        XCTAssertFalse(inspector.sectionLabelsForTesting.contains(L10n.Inspector.metrics))
        XCTAssertEqual(inspector.sectionControlForTesting.segmentCount, inspector.sectionLabelsForTesting.count)
        XCTAssertNil(inspector.deviceMetricsViewController)
        inspector.selectSectionForTesting(inspector.sectionControlForTesting.segmentCount)
        XCTAssertEqual(inspector.selectedTabLabel, "文件")
    }

    func testDeviceMetricsDisplayLocationPersistsAndDefaultsToFloating() {
        let suiteName = "StacioMetricsDisplayLocationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.snapshot().deviceMetricsDisplayLocation, .floating)
        defaults.set("unknown", forKey: "Stacio.Settings.deviceMetricsDisplayLocation")
        XCTAssertEqual(store.snapshot().deviceMetricsDisplayLocation, .floating)
        store.update { settings in
            settings.deviceMetricsDisplayLocation = .terminalBottom
        }
        XCTAssertEqual(store.snapshot().deviceMetricsDisplayLocation, .terminalBottom)
        store.update { settings in
            settings.deviceMetricsDisplayLocation = .floating
        }
        XCTAssertEqual(store.snapshot().deviceMetricsDisplayLocation, .floating)
    }

    func testStatusBarRendersDenseMetricsAndKeepsFixedHeightWhenNarrow() {
        let suiteName = "StacioMetricsStatusBarLayoutTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "status_narrow",
            title: "root@example.com",
            provider: RecordingDeviceMetricsProvider(snapshot: .dense),
            startsPollingAutomatically: false,
            settingsStore: AppSettingsStore(defaults: defaults)
        )

        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 220, height: DeviceMetricsStatusBarViewController.barHeightForLayout)
        controller.refreshMetricsForTesting()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.view.frame.height, DeviceMetricsStatusBarViewController.barHeightForLayout, accuracy: 0.5)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("CPU"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("内存"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/data"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/boot"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.scrollView"))
    }

    func testStatusBarUsesGlassSurfaceResourceIconsHistoryGraphsAndDetailedTooltips() throws {
        let suiteName = "StacioMetricsStatusBarVisualTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "status_visuals",
            title: "root@example.com",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample.with(cpuUsage: 0.95)),
            startsPollingAutomatically: false,
            settingsStore: AppSettingsStore(defaults: defaults)
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: DeviceMetricsStatusBarViewController.barHeightForLayout)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.view.layer?.borderWidth ?? 0, 0)
        let glass = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.glassSurface") as? NSVisualEffectView
        )
        XCTAssertEqual(glass.material, .underWindowBackground)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("worker-01 · Ubuntu 25.10"))
        let statusText = controller.visibleTextSnapshotForTesting
        XCTAssertLessThan(
            try XCTUnwrap(statusText.range(of: "用户")).lowerBound,
            try XCTUnwrap(statusText.range(of: "CPU")).lowerBound
        )

        let cpuLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.CPU") as? NSTextField
        )
        XCTAssertEqual(cpuLabel.textColor, StacioDesignSystem.theme.dangerColor)
        XCTAssertNotNil(cpuLabel.layer?.animation(forKey: "Stacio.Metrics.statusBar.breathingGlow"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.icon.CPU"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.icon.内存"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.icon.磁盘"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.history.CPU"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.history.内存"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.history.磁盘"))
        XCTAssertTrue(controller.detailTextForTesting(title: "磁盘").contains("/data"))
        XCTAssertTrue(controller.detailTextForTesting(title: "磁盘").contains("可用"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.usageIndicator.CPU"))
        XCTAssertEqual(controller.historySampleCountForTesting(title: "CPU"), 1)
        controller.refreshMetricsForTesting()
        controller.refreshMetricsForTesting()
        XCTAssertEqual(controller.historySampleCountForTesting(title: "CPU"), 3)
        let rootDiskLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.disk./") as? NSTextField
        )
        let dataDiskLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.disk./data") as? NSTextField
        )
        XCTAssertEqual(rootDiskLabel.textColor, StacioDesignSystem.theme.successColor)
        XCTAssertEqual(dataDiskLabel.textColor, NSColor.systemOrange)
        XCTAssertNil(rootDiskLabel.layer?.animation(forKey: "Stacio.Metrics.statusBar.breathingGlow"))
        XCTAssertNil(dataDiskLabel.layer?.animation(forKey: "Stacio.Metrics.statusBar.breathingGlow"))
    }

    func testStatusBarHoverDetailsAppearImmediatelyAndStayVisibleAcrossRefreshes() throws {
        let provider = SequenceDeviceMetricsProvider(results: [
            .success(.sample),
            .success(.sample.with(cpuUsage: 0.95))
        ])
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "status_stable_hover",
            title: "root@example.com",
            provider: provider,
            startsPollingAutomatically: false
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1_200, height: DeviceMetricsStatusBarViewController.barHeightForLayout))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        controller.refreshMetricsForTesting()
        controller.view.layoutSubtreeIfNeeded()

        controller.beginHoverDetailForTesting(title: "设备")
        XCTAssertTrue(controller.hoverDetailIsShownForTesting)
        XCTAssertTrue(controller.hoverDetailTextForTesting.contains("主机: worker-01"))
        XCTAssertTrue(controller.hoverDetailTextForTesting.contains("系统: Ubuntu 25.10"))

        controller.beginHoverDetailForTesting(title: "用户")
        XCTAssertTrue(controller.hoverDetailIsShownForTesting)
        XCTAssertTrue(controller.hoverDetailTextForTesting.contains("远端用户: deploy"))

        controller.beginHoverDetailForTesting(title: "连接")
        XCTAssertTrue(controller.hoverDetailIsShownForTesting)
        XCTAssertTrue(controller.hoverDetailTextForTesting.contains("连接目标: root@example.com"))
        controller.endHoverDetailForTesting(title: "连接")
        XCTAssertFalse(controller.hoverDetailIsShownForTesting)

        controller.beginHoverDetailForTesting(title: "CPU")
        let popoverIdentity = try XCTUnwrap(controller.hoverDetailPopoverIdentityForTesting)
        XCTAssertTrue(controller.hoverDetailTextForTesting.contains("当前 CPU 负载: 42%"))
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.hoverDetailIsShownForTesting)
        XCTAssertEqual(controller.hoverDetailPopoverIdentityForTesting, popoverIdentity)
        XCTAssertTrue(controller.hoverDetailTextForTesting.contains("当前 CPU 负载: 95%"))
        controller.endHoverDetailForTesting(title: "CPU")
        XCTAssertFalse(controller.hoverDetailIsShownForTesting)
    }

    func testStatusBarSingleClickHistoryKeepsSelectionAcrossRefreshAndSuppressesHover() throws {
        let provider = SequenceDeviceMetricsProvider(results: [
            .success(.sample), .success(.sample.with(cpuUsage: 0.95)),
            .failure(DeviceMetricsTestError.unavailable)
        ])
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "history_refresh", title: "root@example.com", provider: provider,
            startsPollingAutomatically: false
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1_400, height: DeviceMetricsStatusBarViewController.barHeightForLayout))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        controller.refreshMetricsForTesting()
        controller.view.layoutSubtreeIfNeeded()
        controller.beginHoverDetailForTesting(title: "CPU")
        let label = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.CPU"))
        let gesture = try XCTUnwrap(label.superview?.gestureRecognizers.first as? NSClickGestureRecognizer)
        XCTAssertEqual(gesture.numberOfClicksRequired, 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(gesture.action), to: gesture.target, from: gesture))
        let popover = try XCTUnwrap(controller.historyPopoverForTesting)
        let detail = try XCTUnwrap(popover.contentViewController as? DeviceMetricHistoryDetailViewController)
        detail.setRangeForTesting(lower: 0.2, upper: 0.7)
        XCTAssertTrue(popover.isShown)
        XCTAssertFalse(controller.hoverDetailIsShownForTesting)

        controller.refreshMetricsForTesting()
        controller.beginHoverDetailForTesting(title: "CPU")
        XCTAssertTrue(controller.historyPopoverForTesting === popover)
        XCTAssertTrue(popover.isShown)
        XCTAssertTrue(popover.contentViewController === detail)
        XCTAssertEqual(detail.selectedRangeForTesting.lower, 0.2, accuracy: 0.001)
        XCTAssertEqual(detail.selectedRangeForTesting.upper, 0.7, accuracy: 0.001)
        XCTAssertFalse(controller.hoverDetailIsShownForTesting)

        controller.refreshMetricsForTesting()
        XCTAssertTrue(controller.historyPopoverForTesting === popover)
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(detail.selectedRangeForTesting.lower, 0.2, accuracy: 0.001)
        XCTAssertEqual(detail.selectedRangeForTesting.upper, 0.7, accuracy: 0.001)
    }

    func testStatusBarSwitchingHistoryResourceUsesItsOwnTitleAndUnit() throws {
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "history_resource", title: "root@example.com",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1_400, height: DeviceMetricsStatusBarViewController.barHeightForLayout))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        controller.refreshMetricsForTesting()
        controller.view.layoutSubtreeIfNeeded()
        func openHistory(_ resource: String) throws -> DeviceMetricHistoryDetailViewController {
            let label = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.\(resource)"))
            let gesture = try XCTUnwrap(label.superview?.gestureRecognizers.first as? NSClickGestureRecognizer)
            XCTAssertEqual(gesture.numberOfClicksRequired, 1)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(gesture.action), to: gesture.target, from: gesture))
            return try XCTUnwrap(controller.historyPopoverForTesting?.contentViewController as? DeviceMetricHistoryDetailViewController)
        }
        let cpu = try openHistory("CPU")
        let memory = try openHistory("内存")
        XCTAssertFalse(cpu === memory)
        XCTAssertTrue(memory.view.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "内存已用历史资源使用（B）" })
        XCTAssertEqual(memory.visibleSamplesForTesting.first?.value, Double(DeviceMetricsDisplaySnapshot.sample.memory.usedBytes))

        controller.viewWillDisappear()
        XCTAssertNil(controller.historyPopoverForTesting)
    }

    func testHistorySliderHasUsableHeightAndCanMoveBothHandles() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: (0...24).map {
                DeviceMetricHistorySample(date: start.addingTimeInterval(Double($0) * 3600), value: 0.5)
            }, accentColor: .systemBlue, unit: "%"
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(controller.preferredContentSize)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.range"))
        XCTAssertGreaterThanOrEqual(slider.bounds.height, 24)
        func event(_ type: NSEvent.EventType, _ fraction: CGFloat) throws -> NSEvent {
            let location = slider.convert(NSPoint(x: 12 + (slider.bounds.width - 24) * fraction, y: slider.bounds.midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        slider.mouseDown(with: try event(.leftMouseDown, 0))
        slider.mouseDragged(with: try event(.leftMouseDragged, 0.2))
        slider.mouseUp(with: try event(.leftMouseUp, 0.2))
        slider.mouseDown(with: try event(.leftMouseDown, 1))
        slider.mouseDragged(with: try event(.leftMouseDragged, 0.6))
        slider.mouseUp(with: try event(.leftMouseUp, 0.6))
        XCTAssertEqual(controller.selectedRangeForTesting.lower, 0.2, accuracy: 0.001)
        XCTAssertEqual(controller.selectedRangeForTesting.upper, 0.6, accuracy: 0.001)
    }

    func testHistorySliderCanExpandCoincidentHandlesInEitherDirection() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: [
                DeviceMetricHistorySample(date: start, value: 0.2),
                DeviceMetricHistorySample(date: start.addingTimeInterval(3600), value: 0.5)
            ], accentColor: .systemBlue, unit: "%"
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(controller.preferredContentSize)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.range"))
        func event(_ type: NSEvent.EventType, at fraction: CGFloat, offset: CGFloat = 0) throws -> NSEvent {
            let point = NSPoint(x: 12 + (slider.bounds.width - 24) * fraction + offset, y: slider.bounds.midY)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: slider.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        for (origin, destination, grabOffset) in [
            (0.0, 0.6, 0.0), (0.5, 0.8, 0.0), (1.0, 0.4, 0.0), (0.5, 0.2, 0.0),
            (0.5, 0.2, 4.0), (0.5, 0.8, -4.0)
        ] {
            controller.setRangeForTesting(lower: origin, upper: origin)
            // Grabbing either side of the knob must still permit both drag
            // directions, without depending on a pixel-perfect center click.
            slider.mouseDown(with: try event(.leftMouseDown, at: origin, offset: grabOffset))
            slider.mouseDragged(with: try event(.leftMouseDragged, at: destination, offset: grabOffset))
            slider.mouseUp(with: try event(.leftMouseUp, at: destination, offset: grabOffset))
            XCTAssertEqual(controller.selectedRangeForTesting.lower, min(origin, destination), accuracy: 0.001)
            XCTAssertEqual(controller.selectedRangeForTesting.upper, max(origin, destination), accuracy: 0.001)
        }
    }

    func testHistoryHandleClickDoesNotChangeDatesBeforeOpeningTimeEditor() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: [
                DeviceMetricHistorySample(date: start, value: 0.2),
                DeviceMetricHistorySample(date: start.addingTimeInterval(3600), value: 0.5)
            ], accentColor: .systemBlue, unit: "%"
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(controller.preferredContentSize)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.range"))
        controller.setRangeForTesting(lower: 0.2, upper: 0.8)
        for (fraction, offset) in [(0.2, -8.0), (0.2, 8.0), (0.8, -8.0), (0.8, 8.0)] {
            let location = slider.convert(NSPoint(x: 12 + (slider.bounds.width - 24) * fraction + offset, y: slider.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            // The first click of a double-click should leave the selected
            // dates intact, so cancelling the editor cannot change them.
            slider.mouseDown(with: try event(.leftMouseDown))
            slider.mouseUp(with: try event(.leftMouseUp))
            let editor = try XCTUnwrap(controller.makeTimeRangeEditor())
            XCTAssertEqual(editor.startPicker.dateValue.timeIntervalSince(start), 720, accuracy: 0.001)
            XCTAssertEqual(editor.endPicker.dateValue.timeIntervalSince(start), 2880, accuracy: 0.001)
        }
    }

    func testHistoryDragKeepsItsTimeAxisUntilMouseUpThenAppliesLatestSamples() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0...12).map {
            DeviceMetricHistorySample(date: start.addingTimeInterval(Double($0) * 3600), value: 0.5)
        }
        for destination in [0.8, 0.6] {
            let controller = DeviceMetricHistoryDetailViewController(
                resourceTitle: "CPU", samples: Array(samples.prefix(11)), accentColor: .systemBlue, unit: "%"
            )
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(controller.preferredContentSize)
            defer { window.close() }
            controller.view.layoutSubtreeIfNeeded()
            controller.setRangeForTesting(lower: 0.2, upper: 0.8)
            let slider = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.range"))
            func event(_ type: NSEvent.EventType, fraction: Double) throws -> NSEvent {
                let location = slider.convert(NSPoint(x: 12 + (slider.bounds.width - 24) * fraction + 4, y: slider.bounds.midY), to: nil)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            slider.mouseDown(with: try event(.leftMouseDown, fraction: 0.8))
            controller.updateHistorySamples(Array(samples.prefix(12)))
            controller.updateHistorySamples(samples)
            slider.mouseDragged(with: try event(.leftMouseDragged, fraction: destination))
            slider.mouseUp(with: try event(.leftMouseUp, fraction: destination))
            let chart = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.chart") as? DeviceMetricHistoryChartView)
            let range = try XCTUnwrap(chart.timeRange)
            XCTAssertEqual(range.start.timeIntervalSince(start), 7200, accuracy: 0.001)
            XCTAssertEqual(range.end.timeIntervalSince(start), destination * 36000, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(controller.makeTimeRangeEditor()).endPicker.maxDate, samples.last?.date)
        }
    }

    func testHistoryDismissalEndsDragAndAppliesPendingEmptyHistory() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            DeviceMetricHistorySample(date: start, value: 0.2),
            DeviceMetricHistorySample(date: start.addingTimeInterval(3600), value: 0.5)
        ]
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: samples, accentColor: .systemBlue, unit: "%"
        )
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(controller.preferredContentSize)
        defer { window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.range"))
        let location = slider.convert(NSPoint(x: slider.bounds.width - 12, y: slider.bounds.midY), to: nil)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        slider.mouseDown(with: mouseDown)
        controller.updateHistorySamples([])
        let chart = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.chart") as? DeviceMetricHistoryChartView)
        XCTAssertNotNil(chart.timeRange)
        // A disappearing popover may never receive mouseUp. It must still
        // release the frozen time axis and accept later refreshes normally.
        controller.viewWillDisappear()
        XCTAssertNil(chart.timeRange)
        XCTAssertTrue(controller.visibleSamplesForTesting.isEmpty)
        controller.updateHistorySamples(samples)
        XCTAssertEqual(chart.timeRange, DateInterval(start: start, duration: 3600))
        XCTAssertFalse(controller.visibleSamplesForTesting.isEmpty)
    }

    func testHistoryTimeEditorFitsBothDatePickersInsideInlineCard() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: [
                DeviceMetricHistorySample(date: start, value: 0.2),
                DeviceMetricHistorySample(date: start.addingTimeInterval(3600), value: 0.5)
            ], accentColor: .systemBlue, unit: "%"
        )
        let editor = try XCTUnwrap(controller.makeTimeRangeEditor())
        let window = NSWindow(contentRect: editor.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.layoutSubtreeIfNeeded()
        let accessory = editor
        XCTAssertGreaterThan(accessory.frame.height, 150)
        for picker in [editor.startPicker, editor.endPicker] {
            let pickerRect = picker.convert(picker.bounds, to: accessory)
            XCTAssertTrue(accessory.bounds.contains(pickerRect), "Date picker clipped: \(pickerRect) outside \(accessory.bounds)")
            XCTAssertGreaterThanOrEqual(picker.bounds.width, picker.fittingSize.width)
            XCTAssertEqual(picker.minDate, start)
            XCTAssertEqual(picker.maxDate, start.addingTimeInterval(3600))
        }
        let startRect = editor.startPicker.convert(editor.startPicker.bounds, to: accessory)
        let endRect = editor.endPicker.convert(editor.endPicker.bounds, to: accessory)
        XCTAssertFalse(startRect.intersects(endRect))
    }

    func testStatusBarColorsEachDiskPartitionIndependentlyWithoutDiskGraph() throws {
        let snapshot = DeviceMetricsDisplaySnapshot.sample.with(disks: [
            DeviceDiskDisplayUsage(mountPath: "/", usedBytes: 25, totalBytes: 100),
            DeviceDiskDisplayUsage(mountPath: "/warning", usedBytes: 80, totalBytes: 100),
            DeviceDiskDisplayUsage(mountPath: "/danger", usedBytes: 95, totalBytes: 100)
        ])
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "status_disk_colors",
            title: "root@example.com",
            provider: RecordingDeviceMetricsProvider(snapshot: snapshot),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        let normal = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.disk./") as? NSTextField
        )
        let warning = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.disk./warning") as? NSTextField
        )
        let danger = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.disk./danger") as? NSTextField
        )

        XCTAssertEqual(normal.textColor, StacioDesignSystem.theme.successColor)
        XCTAssertEqual(warning.textColor, NSColor.systemOrange)
        XCTAssertEqual(danger.textColor, StacioDesignSystem.theme.dangerColor)
        XCTAssertNil(normal.layer?.animation(forKey: "Stacio.Metrics.statusBar.breathingGlow"))
        XCTAssertNil(warning.layer?.animation(forKey: "Stacio.Metrics.statusBar.breathingGlow"))
        XCTAssertNotNil(danger.layer?.animation(forKey: "Stacio.Metrics.statusBar.breathingGlow"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.statusBar.history.磁盘"))
        XCTAssertEqual(controller.historySampleCountForTesting(title: "磁盘"), 0)
    }

    func testStatusBarMarshalsBackgroundProviderCallbacksToMainThread() async throws {
        let provider = BackgroundQueueDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "status_background",
            title: "root@example.com",
            provider: provider,
            startsPollingAutomatically: false
        )
        let didUpdate = expectation(description: "status bar update")
        let recorder = MainThreadUpdateRecorder(expectation: didUpdate)
        controller.metricsDidUpdate = {
            recorder.record()
        }

        controller.loadView()
        controller.refreshMetricsForTesting()

        await fulfillment(of: [didUpdate], timeout: 1.0)
        let rendered = await metricsDashboardEventually {
            controller.visibleTextSnapshotForTesting.contains("42%")
        }
        XCTAssertTrue(rendered)
        XCTAssertEqual(recorder.values, [true])
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func testStatusBarReportsItsInitialHeightForWorkspaceLayout() {
        let controller = DeviceMetricsStatusBarViewController(
            runtimeID: "status_height",
            title: "root@example.com",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )
        var reportedHeights = 0
        controller.barHeightDidChange = {
            reportedHeights += 1
        }

        controller.loadView()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 320,
            height: DeviceMetricsStatusBarViewController.barHeightForLayout
        )
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(reportedHeights, 1)
    }
    func testDashboardRendersRealtimeDeviceMetricsInFloatingChartPanel() throws {
        let suiteName = "StacioMetricsOverviewVisuals-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let alertCoordinator = DeviceMetricsAlertCoordinator(
            settingsProvider: { settingsStore.snapshot() },
            notifier: NoopDeviceMetricsAlertNotifier(),
            thresholdDefaults: defaults
        )
        alertCoordinator.updateThreshold(10, for: .networkIO, settingsStore: settingsStore)
        alertCoordinator.updateThreshold(10, for: .diskIO, settingsStore: settingsStore)
        let provider = RecordingDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore,
            alertCoordinator: alertCoordinator
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 790)
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertTrue(controller.usesArrowCursorForTesting)
        XCTAssertEqual(controller.view.accessibilityIdentifier(), "Stacio.Metrics.dashboard.term_metrics")
        XCTAssertEqual(controller.view.layer?.cornerRadius ?? 0, 0)
        XCTAssertEqual(controller.view.layer?.backgroundColor, NSColor.clear.cgColor)
        let panel = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.codexPanel"))
        XCTAssertNotNil(panel.shadow)
        XCTAssertLessThanOrEqual(panel.shadow?.shadowBlurRadius ?? 0, 12)
        XCTAssertEqual(
            panel.layer?.backgroundColor,
            StacioDesignSystem.resolvedLayerColor(
                StacioDesignSystem.metricsFloatingSurfaceColor(for: panel),
                for: panel
            )
        )
        XCTAssertEqual(panel.layer?.cornerRadius, 7)
        XCTAssertEqual(panel.layer?.borderWidth ?? 0, 0)
        XCTAssertNil(panel.layer?.borderColor)
        let cpuTile = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.tile.CPU"))
        XCTAssertEqual(
            cpuTile.layer?.backgroundColor,
            StacioDesignSystem.resolvedLayerColor(
                StacioDesignSystem.metricsFloatingSurfaceColor(for: cpuTile),
                for: cpuTile
            )
        )
        XCTAssertEqual(cpuTile.layer?.cornerRadius, 7)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.overview"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuLineChart"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.memoryLineChart"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuGauge"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.memoryGauge"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("设备看板"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("root@172.16.10.250"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.system"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("系统"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("主机名称"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("worker-01"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("登录用户"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("deploy"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("系统架构"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("x86_64"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("操作系统"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Ubuntu 25.10"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("运行时长"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("14天"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("内核版本"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("6.8.0-64-generic"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("概览"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("CPU"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("42%"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("8 CPU"))
        let cpuCoreButton = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuCoreButton") as? NSButton)
        XCTAssertEqual(cpuCoreButton.title, "8 CPU")
        XCTAssertEqual(cpuCoreButton.cell?.lineBreakMode, .byTruncatingMiddle)
        XCTAssertEqual(cpuTile.frame.height, 104, accuracy: 0.5)
        let cpuCorePopoverText = controller.cpuCorePopoverPreviewTextSnapshotForTesting
        XCTAssertTrue(cpuCorePopoverText.hasPrefix("Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz\n"))
        XCTAssertTrue(cpuCorePopoverText.contains("CPU 核心"))
        XCTAssertTrue(cpuCorePopoverText.contains("Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"))
        XCTAssertTrue(cpuCorePopoverText.contains("8 CPU"))
        XCTAssertTrue(cpuCorePopoverText.contains("18.2%"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("内存"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("5.0 GB / 16.0 GB"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("网络"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↓ 下载 12.0 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↑ 上传 1.5 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("下载 12.0 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("上传 1.5 MB/s"))
        let overviewNetworkDownloadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.network.download") as? NSTextField
        )
        XCTAssertEqual(overviewNetworkDownloadLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewNetworkDownloadLabel.textColor, StacioDesignSystem.theme.dangerColor)
        XCTAssertNotNil(overviewNetworkDownloadLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        let overviewNetworkUploadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.network.upload") as? NSTextField
        )
        XCTAssertEqual(overviewNetworkUploadLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewNetworkUploadLabel.textColor, StacioDesignSystem.theme.successColor)
        XCTAssertNil(overviewNetworkUploadLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        let networkPicker = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkPicker") as? NSPopUpButton)
        XCTAssertTrue(networkPicker.isEnabled)
        XCTAssertTrue(networkPicker.item(at: 0)?.isEnabled ?? false)
        XCTAssertEqual(networkPicker.contentTintColor, StacioDesignSystem.theme.primaryTextColor)
        let networkDownloadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkRate.download.ens160") as? NSTextField
        )
        XCTAssertEqual(networkDownloadLabel.stringValue, "↓ 下载 12.0 MB/s")
        XCTAssertEqual(networkDownloadLabel.textColor, StacioDesignSystem.theme.accentColor)
        XCTAssertEqual(networkDownloadLabel.font?.pointSize, 13)
        let networkUploadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkRate.upload.ens160") as? NSTextField
        )
        XCTAssertEqual(networkUploadLabel.stringValue, "↑ 上传 1.5 MB/s")
        XCTAssertEqual(networkUploadLabel.textColor, StacioDesignSystem.theme.successColor)
        XCTAssertEqual(networkUploadLabel.font?.pointSize, 13)
        let networkInterfaceLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkInterface.ens160") as? NSTextField
        )
        XCTAssertEqual(networkInterfaceLabel.font?.pointSize, 13)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("磁盘读写"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↓ 读 10.0 MB/s"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("↑ 写 1.0 MB/s"))
        let overviewDiskReadLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.disk.read") as? NSTextField
        )
        XCTAssertEqual(overviewDiskReadLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewDiskReadLabel.textColor, StacioDesignSystem.theme.dangerColor)
        XCTAssertNotNil(overviewDiskReadLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        let overviewDiskWriteLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.overview.disk.write") as? NSTextField
        )
        XCTAssertEqual(overviewDiskWriteLabel.font?.pointSize, 14)
        XCTAssertEqual(overviewDiskWriteLabel.textColor, NSColor.systemOrange)
        XCTAssertNil(overviewDiskWriteLabel.layer?.animation(forKey: "Stacio.Metrics.ioBreathingGlow"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("/proc/diskstats"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("磁盘"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/data"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("78%"))
        let rootDiskTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskTitle./") as? NSTextField
        )
        XCTAssertEqual(rootDiskTitle.font?.pointSize, 13)
        XCTAssertEqual(rootDiskTitle.textColor, StacioDesignSystem.theme.accentColor)
        let rootDiskDetail = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskDetail./") as? NSTextField
        )
        XCTAssertEqual(rootDiskDetail.font?.pointSize, 12)
        XCTAssertEqual(rootDiskDetail.textColor, StacioDesignSystem.theme.successColor)
        let dataDiskDetail = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskDetail./data") as? NSTextField
        )
        XCTAssertEqual(dataDiskDetail.textColor, NSColor.systemOrange)
        controller.refreshThemeForEffectiveAppearanceChangeForTesting(appearance: controller.view.effectiveAppearance)
        let primaryTextColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.primaryTextColor,
            for: controller.view.effectiveAppearance
        )
        let successTextColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.successColor,
            for: controller.view.effectiveAppearance
        )
        let dangerTextColor = StacioDesignSystem.resolvedColor(
            StacioDesignSystem.theme.dangerColor,
            for: controller.view.effectiveAppearance
        )
        let systemHostnameLabel = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemLabel.hostname") as? NSTextField
        )
        let systemHostnameValue = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemValue.hostname") as? NSTextField
        )
        let overviewTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.overview.title") as? NSTextField
        )
        let networkTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network.title") as? NSTextField
        )
        let diskTitle = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks.title") as? NSTextField
        )
        XCTAssertEqual(systemHostnameLabel.textColor, primaryTextColor)
        XCTAssertEqual(systemHostnameValue.textColor, primaryTextColor)
        XCTAssertEqual(overviewTitle.textColor, primaryTextColor)
        XCTAssertEqual(networkTitle.textColor, primaryTextColor)
        XCTAssertEqual(diskTitle.textColor, primaryTextColor)
        XCTAssertEqual(overviewNetworkDownloadLabel.textColor, dangerTextColor)
        XCTAssertEqual(networkUploadLabel.textColor, successTextColor)
        let cpuChart = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.cpuLineChart"))
        XCTAssertGreaterThanOrEqual(cpuChart.superview?.frame.width ?? 0, 86)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.diskPie./data"))
        XCTAssertEqual(metricsDashboardRootWidthConstraintCount(in: controller.view), 0)
        XCTAssertTrue(controller.textFieldSupportsSelectionForTesting(accessibilityIdentifier: "Stacio.Metrics.systemValue.operatingSystem"))
        XCTAssertTrue(controller.textFieldSupportsSelectionForTesting(accessibilityIdentifier: "Stacio.Metrics.section.overview.title"))
        XCTAssertTrue(controller.textFieldSupportsSelectionForTesting(accessibilityIdentifier: "Stacio.Metrics.networkRate.download.ens160"))
    }

    func testDashboardOffersFullOperatingSystemPopoverWhenNameIsTruncated() throws {
        let longOperatingSystem = "Anolis OS 8.8 (RHCK) 4.19.90-372.32.1.el8.x86_64 Enterprise Linux Compatible"
        let snapshot = DeviceMetricsDisplaySnapshot(
            cpuUsage: 0.24,
            cpuCoreUsages: [
                DeviceCPUCoreDisplayUsage(index: 0, usage: 0.12),
                DeviceCPUCoreDisplayUsage(index: 1, usage: 0.36)
            ],
            system: DeviceSystemDisplayInfo(
                hostname: "legacy-node",
                currentUser: "root",
                architecture: "x86_64",
                operatingSystem: longOperatingSystem,
                uptimeText: "2小时",
                kernelVersion: "4.19.90-372.32.1.el8.x86_64",
                cpuModel: "Hygon C86 7185 32-core Processor"
            ),
            memory: DeviceMemoryDisplayUsage(usedBytes: 1_000, totalBytes: 4_000),
            networks: [],
            disks: []
        )
        let provider = RecordingDeviceMetricsProvider(snapshot: snapshot)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_long_os",
            title: "root@legacy-node",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 190, height: 520)
        controller.view.layoutSubtreeIfNeeded()
        let osValue = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemValue.operatingSystem") as? NSTextField
        )
        osValue.frame.size.width = 82

        XCTAssertTrue(controller.isOperatingSystemValueTruncatedForTesting)
        let popoverText = controller.operatingSystemInfoPopoverPreviewTextSnapshotForTesting
        XCTAssertTrue(popoverText.contains("操作系统"))
        XCTAssertTrue(popoverText.contains(longOperatingSystem))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("Hygon C86 7185 32-core Processor"))
        XCTAssertTrue(
            controller.cpuCorePopoverPreviewTextSnapshotForTesting.hasPrefix(
                "Hygon C86 7185 32-core Processor\n"
            )
        )
    }

    func testOperatingSystemLabelHandlesPointerExitToDismissPopover() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_os_hover",
            title: "root@legacy-node",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        let osValue = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.systemValue.operatingSystem") as? NSTextField
        )
        let selector = #selector(NSResponder.mouseExited(with:))
        let labelMethod = try XCTUnwrap(class_getInstanceMethod(type(of: osValue), selector))
        let textFieldMethod = try XCTUnwrap(class_getInstanceMethod(NSTextField.self, selector))
        let labelImplementation = unsafeBitCast(
            method_getImplementation(labelMethod),
            to: UnsafeRawPointer.self
        )
        let textFieldImplementation = unsafeBitCast(
            method_getImplementation(textFieldMethod),
            to: UnsafeRawPointer.self
        )

        XCTAssertNotEqual(labelImplementation, textFieldImplementation)
    }

    func testPreferredFloatingHeightPreservesUsableLayoutForExtremelyNarrowWorkspace() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_narrow",
            title: "root@legacy-node",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 790)
        controller.view.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.content")
        )
        _ = controller.preferredFloatingHeight(width: 300)
        let usableWidth = content.frame.width

        XCTAssertEqual(usableWidth, 280, accuracy: 0.5)
        for width in [CGFloat.zero, 1, 20] {
            let height = controller.preferredFloatingHeight(width: width)

            XCTAssertTrue(height.isFinite)
            XCTAssertEqual(height, 180, accuracy: 0.5)
            XCTAssertEqual(content.frame.width, usableWidth, accuracy: 0.5)
            let containerBounds = try XCTUnwrap(content.superview?.bounds)
            XCTAssertGreaterThanOrEqual(content.frame.minX, containerBounds.minX - 0.5)
            XCTAssertLessThanOrEqual(content.frame.maxX, containerBounds.maxX + 0.5)
        }

        let freshController = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_narrow_fresh",
            title: "root@legacy-node",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )
        freshController.loadView()
        freshController.refreshMetricsForTesting()
        let freshContent = try XCTUnwrap(
            freshController.view.firstSubview(withIdentifier: "Stacio.Metrics.content")
        )
        let freshHeight = freshController.preferredFloatingHeight(width: 1)

        XCTAssertTrue(freshHeight.isFinite)
        XCTAssertEqual(freshHeight, 180, accuracy: 0.5)
        XCTAssertNotEqual(freshContent.frame.width, 1)
        let freshContainerBounds = try XCTUnwrap(freshContent.superview?.bounds)
        XCTAssertGreaterThanOrEqual(freshContent.frame.minX, freshContainerBounds.minX - 0.5)
        XCTAssertLessThanOrEqual(freshContent.frame.maxX, freshContainerBounds.maxX + 0.5)
    }

    func testRepeatedPreferredFloatingHeightAtSameWidthStaysOnCachedDragPath() {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_resize_performance",
            title: "root@resize-performance",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 790)
        controller.view.layoutSubtreeIfNeeded()
        _ = controller.preferredFloatingHeight(width: 360)

        let startedAt = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            _ = controller.preferredFloatingHeight(width: 360)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt

        XCTAssertLessThan(
            elapsed,
            0.03,
            "拖动外层分隔线且看板宽度未变时，不应重复同步布局整棵指标视图树"
        )
    }

    func testPreferredFloatingHeightCacheInvalidatesWhenMetricsChangeContentHeight() {
        let provider = SequenceDeviceMetricsProvider(results: [
            .success(.sample),
            .success(.dense)
        ])
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_resize_cache_invalidation",
            title: "root@resize-cache-invalidation",
            provider: provider,
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 790)

        controller.refreshMetricsForTesting()
        let initialHeight = controller.preferredFloatingHeight(width: 360)
        controller.refreshMetricsForTesting()
        let updatedHeight = controller.preferredFloatingHeight(width: 360)

        XCTAssertGreaterThan(
            updatedHeight,
            initialHeight,
            "指标内容增多后必须重新测量看板高度，不能复用拖动期间的旧缓存"
        )
    }

    func testDashboardMarksCustomMetricDrawingsDirtyWhenAppearanceChanges() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        let initialInvalidationCount = controller.metricDrawingAppearanceInvalidationCountForTesting

        controller.view.viewDidChangeEffectiveAppearance()

        XCTAssertGreaterThan(controller.metricDrawingAppearanceInvalidationCountForTesting, initialInvalidationCount)
    }

    func testDashboardRefreshesPanelColorsForEffectiveAppearanceChanges() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        controller.loadView()
        window.contentView = controller.view
        controller.refreshMetricsForTesting()
        let panel = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.codexPanel"))

        controller.refreshThemeForEffectiveAppearanceChangeForTesting(
            appearance: try XCTUnwrap(NSAppearance(named: .aqua))
        )
        let lightBackground = try XCTUnwrap(panel.layer?.backgroundColor)

        controller.refreshThemeForEffectiveAppearanceChangeForTesting(
            appearance: try XCTUnwrap(NSAppearance(named: .darkAqua))
        )
        let darkBackground = try XCTUnwrap(panel.layer?.backgroundColor)

        XCTAssertLessThan(darkBackground.stacioTestRelativeLuminance, lightBackground.stacioTestRelativeLuminance)
    }

    func testDashboardDefaultsToActiveNetworkInterfacesAndAllowsManualMultiSelection() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .dense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkPicker"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens160"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("veth-extra"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("docker0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("br-e76d70614a3c"))

        controller.setSelectedNetworkInterfacesForTesting(["docker0", "ens160"])

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("docker0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens160"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("veth-extra"))
    }

    func testDashboardKeepsContainerOverlayNetworksOutOfAutomaticSelection() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@k8s-node",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens192"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("cali1234"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("flannel.1"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("ovn-k8s-mp0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("tailscale0"))

        controller.setSelectedNetworkInterfacesForTesting(["ens192", "cni0", "tailscale0"])

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens192"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("tailscale0"))
    }

    func testDashboardExplainsAutomaticallyHiddenVirtualNetworkInterfaces() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7-docker",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("已自动隐藏 5 个虚拟网卡"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("可在网卡菜单手动显示"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("cni0"))

        controller.setSelectedNetworkInterfacesForTesting(["ens192", "cni0", "tailscale0"])

        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("已自动隐藏"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("tailscale0"))
    }

    func testDashboardVirtualNetworkHintWrapsToAvailableNetworkWidth() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7-docker",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.view.frame = NSRect(x: 0, y: 0, width: 190, height: 790)
        controller.view.layoutSubtreeIfNeeded()

        let hint = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.networkVirtualHint") as? NSTextField
        )
        XCTAssertEqual(hint.stringValue, "已自动隐藏 5 个虚拟网卡\n可在网卡菜单手动显示")
        XCTAssertEqual(hint.maximumNumberOfLines, 2)
        XCTAssertEqual(hint.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(hint.font?.pointSize, 11)
        XCTAssertGreaterThan(hint.bounds.width, 0)
        XCTAssertEqual(hint.preferredMaxLayoutWidth, hint.bounds.width, accuracy: 1)
        XCTAssertGreaterThan(hint.intrinsicContentSize.height, 20)
        XCTAssertGreaterThanOrEqual(hint.bounds.height, hint.intrinsicContentSize.height - 1)
    }

    func testDashboardExplainsInitialCpuSampleAndHiddenDiskCount() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .initialDense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos6",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("等待第二次采样"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("另有 1 个挂载点"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("/mnt/backup"))
    }

    func testDashboardReadsDisplaySettingsForNetworkDiskVisibilityAndDiskLimit() throws {
        let suiteName = "StacioMetricsDisplaySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsShowNetworkSection = false
            settings.deviceMetricsShowDiskSection = true
            settings.deviceMetricsDiskMountLimit = 2
        }
        let provider = RecordingDeviceMetricsProvider(snapshot: .dense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network"))
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("网络"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("ens160"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/data"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("/boot"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("另有 4 个挂载点"))

        settingsStore.update { settings in
            settings.deviceMetricsShowDiskSection = false
        }
        let diskHiddenController = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_hidden_disk",
            title: "root@centos7",
            provider: RecordingDeviceMetricsProvider(snapshot: .dense),
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        diskHiddenController.loadView()
        diskHiddenController.refreshMetricsForTesting()

        XCTAssertNil(diskHiddenController.view.firstSubview(withIdentifier: "Stacio.Metrics.section.network"))
        XCTAssertNil(diskHiddenController.view.firstSubview(withIdentifier: "Stacio.Metrics.section.disks"))
        XCTAssertFalse(diskHiddenController.visibleTextSnapshotForTesting.contains("磁盘"))
        XCTAssertFalse(diskHiddenController.visibleTextSnapshotForTesting.contains("/data"))
    }

    func testDashboardCanDisableAutomaticVirtualNetworkFiltering() throws {
        let suiteName = "StacioMetricsNetworkFilterSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsHideVirtualNetworkInterfaces = false
        }
        let provider = RecordingDeviceMetricsProvider(snapshot: .containerOverlayNetworks)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7-docker",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("ens192"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("cni0"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("tailscale0"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("已自动隐藏"))
    }

    func testDashboardRespectsConfiguredHistorySampleLimit() throws {
        let suiteName = "StacioMetricsHistorySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsHistorySampleCount = 3
        }
        let provider = SequenceDeviceMetricsProvider(results: [
            .success(.sample.with(cpuUsage: 0.10)),
            .success(.sample.with(cpuUsage: 0.20)),
            .success(.sample.with(cpuUsage: 0.30)),
            .success(.sample.with(cpuUsage: 0.40)),
            .success(.sample.with(cpuUsage: 0.50))
        ])
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@centos7",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        (0..<5).forEach { _ in controller.refreshMetricsForTesting() }

        XCTAssertEqual(controller.chartHistorySampleCountsForTesting.cpu, 3)
        XCTAssertEqual(controller.chartHistorySampleCountsForTesting.memory, 3)
    }

    func testDashboardShowsChineseUnavailableStateWhenMetricsFail() throws {
        let provider = RecordingDeviceMetricsProvider(error: DeviceMetricsTestError.unavailable)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("采集失败"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Linux 兼容探针"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("/proc"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("df"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("CentOS"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Ubuntu"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Debian"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Alpine"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.localizedCaseInsensitiveContains("DeviceMetricsTestError"))
    }

    func testDashboardMarshalsBackgroundProviderCallbacksToMainThread() async throws {
        let provider = BackgroundQueueDeviceMetricsProvider(snapshot: .sample)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )
        let didUpdate = expectation(description: "metrics update")
        let recorder = MainThreadUpdateRecorder(expectation: didUpdate)
        controller.metricsDidUpdate = {
            recorder.record()
        }

        controller.loadView()
        controller.refreshMetricsForTesting()

        await fulfillment(of: [didUpdate], timeout: 1.0)
        let rendered = await metricsDashboardEventually {
            controller.visibleTextSnapshotForTesting.contains("42%")
        }
        XCTAssertTrue(rendered)
        XCTAssertEqual(recorder.values, [true])
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func testDashboardCanKeepLastSuccessfulMetricsWhenRefreshFails() throws {
        let suiteName = "StacioMetricsSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.deviceMetricsRefreshIntervalSeconds = 7
            settings.deviceMetricsKeepLastSnapshotOnFailure = true
        }
        let provider = SequenceDeviceMetricsProvider(results: [
            .success(.sample),
            .failure(DeviceMetricsTestError.unavailable)
        ])
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false,
            settingsStore: settingsStore
        )

        controller.loadView()
        controller.refreshMetricsForTesting()
        controller.refreshMetricsForTesting()

        XCTAssertEqual(provider.refreshCount, 2)
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("42%"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("上次成功数据"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("7 秒"))
        XCTAssertEqual(
            controller.historySamplesForTesting(metric: .cpuUsage).count,
            1,
            "失败刷新不得把上次成功样本重复写入历史"
        )
        XCTAssertEqual(
            controller.historySamplesForTesting(metric: .memoryUsage).count,
            1,
            "失败刷新不得把上次成功内存样本重复写入历史"
        )
    }

    func testDashboardExplainsWhichLinuxProbeSectionFailed() throws {
        let provider = RecordingDeviceMetricsProvider(
            error: SshRuntimeError.Transport(message: "METRICS_PROBE_MISSING_MEMORY:/proc/meminfo")
        )
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("无法读取 /proc/meminfo"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("内存探针不可用"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("主流 Linux"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("CentOS/RHEL"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Ubuntu"))
        XCTAssertTrue(controller.visibleTextSnapshotForTesting.contains("Alpine"))
        XCTAssertFalse(controller.visibleTextSnapshotForTesting.contains("METRICS_PROBE_MISSING_MEMORY"))
    }

    func testDashboardUsesVerticalScrollViewSoItDoesNotLockWindowHeight() throws {
        let provider = RecordingDeviceMetricsProvider(snapshot: .dense)
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics",
            title: "root@172.16.10.250",
            provider: provider,
            startsPollingAutomatically: false
        )

        controller.loadView()
        controller.refreshMetricsForTesting()

        let scrollView = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Metrics.scrollView") as? NSScrollView
        )
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertLessThanOrEqual(controller.view.fittingSize.height, 360)
    }

    func testDashboardCapturesTimestampedHistoryForEachResource() throws {
        let controller = DeviceMetricsDashboardViewController(
            runtimeID: "term_metrics_history",
            title: "root@history",
            provider: RecordingDeviceMetricsProvider(snapshot: .sample),
            startsPollingAutomatically: false
        )
        controller.loadView()
        controller.refreshMetricsForTesting()

        XCTAssertEqual(controller.historySamplesForTesting(metric: .cpuUsage).count, 1)
        XCTAssertEqual(controller.historySamplesForTesting(metric: .memoryUsage).count, 1)
        XCTAssertEqual(controller.historySamplesForTesting(metric: .networkIO).count, 1)
        XCTAssertEqual(controller.historySamplesForTesting(metric: .diskIO).count, 1)
        XCTAssertEqual(controller.diskUsageHistorySamplesForTesting(mountPath: "/").count, 1)
        XCTAssertLessThanOrEqual(
            controller.historySamplesForTesting(metric: .memoryUsage).first!.date,
            Date()
        )
    }

    func testHistoryDetailAggregatesSamplesAndExportsPNG() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<6).map {
            DeviceMetricHistorySample(date: base.addingTimeInterval(Double($0) * 60), value: Double($0 + 1))
        }
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU",
            samples: samples,
            accentColor: .systemBlue
        )
        controller.loadView()

        XCTAssertFalse(controller.visibleSamplesForTesting.isEmpty)
        XCTAssertFalse(controller.rangeTextForTesting.contains("Self.dateText"))
        XCTAssertTrue(controller.rangeTextForTesting.contains("2023-11-"))
        let png = try XCTUnwrap(controller.exportPNGDataForTesting())
        XCTAssertGreaterThan(png.count, 1_000)
        XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testHistoryDefaultsToMinuteRangeWithRawSamples() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: (0...5).map {
                DeviceMetricHistorySample(date: start.addingTimeInterval(Double($0) * 2), value: 0.5)
            }, accentColor: .systemBlue, unit: "%"
        )
        controller.loadView()
        let segmented = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.granularity") as? NSSegmentedControl)
        XCTAssertEqual(segmented.selectedSegment, 0)
        XCTAssertEqual(controller.visibleSamplesForTesting.count, 6)
        XCTAssertNotNil(controller.rangeTextForTesting.range(of: #"\d{2}:\d{2}:\d{2}"#, options: .regularExpression))
        XCTAssertTrue(controller.exportTimeRangeText.hasSuffix("按分钟范围显示 · 原始采样"))
    }

    func testHistoryTimeEditorStaysInParentPopoverAndAppliesAbsoluteDatesAfterRefresh() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0...120).map {
            DeviceMetricHistorySample(date: start.addingTimeInterval(Double($0) * 60), value: 0.5)
        }
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: Array(samples.prefix(61)), accentColor: .systemBlue, unit: "%"
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        popover.show(relativeTo: NSRect(x: 300, y: 10, width: 80, height: 20), of: try XCTUnwrap(window.contentView), preferredEdge: .maxY)
        defer { popover.close(); window.close() }
        controller.view.layoutSubtreeIfNeeded()
        controller.setRangeForTesting(lower: 0.2, upper: 0.8)
        let slider = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.range"))
        let historyWindow = try XCTUnwrap(controller.view.window)
        func openEditor(fraction: Double) throws -> DeviceMetricTimeRangeEditorView {
            let point = slider.convert(NSPoint(x: 12 + (slider.bounds.width - 24) * fraction, y: slider.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: historyWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            slider.mouseDown(with: event)
            controller.view.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.timeEditor") as? DeviceMetricTimeRangeEditorView)
            XCTAssertTrue(popover.isShown)
            XCTAssertTrue(editor.window === historyWindow)
            XCTAssertNil(NSApp.modalWindow)
            XCTAssertTrue(controller.view.bounds.contains(editor.convert(editor.bounds, to: controller.view)))
            return editor
        }
        let editor = try openEditor(fraction: 0.2)
        editor.startPicker.dateValue = start.addingTimeInterval(1234)
        editor.endPicker.dateValue = start.addingTimeInterval(2468)
        controller.updateHistorySamples(samples)
        let apply = try XCTUnwrap(editor.firstSubview(withIdentifier: "Stacio.Metrics.history.applyTimeRange") as? NSButton)
        apply.performClick(nil)
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.timeEditor"))
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(controller.selectedRangeForTesting.lower, 1234.0 / 7200, accuracy: 0.0001)
        XCTAssertEqual(controller.selectedRangeForTesting.upper, 2468.0 / 7200, accuracy: 0.0001)
        let reopened = try openEditor(fraction: controller.selectedRangeForTesting.upper)
        reopened.startPicker.dateValue = start
        let cancel = try XCTUnwrap(reopened.firstSubview(withIdentifier: "Stacio.Metrics.history.cancelTimeRange") as? NSButton)
        cancel.performClick(nil)
        XCTAssertTrue(popover.isShown)
        XCTAssertEqual(controller.selectedRangeForTesting.lower, 1234.0 / 7200, accuracy: 0.0001)
    }

    func testHistoryHoverSnapsToSampleWithSecondPrecisionAndClearsOutsidePlot() throws {
        let chart = DeviceMetricHistoryChartView(frame: NSRect(x: 0, y: 0, width: 580, height: 270))
        let window = NSWindow(contentRect: chart.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chart
        defer { window.close() }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        chart.samples = [DeviceMetricHistorySample(date: start, value: 0.1),
                         DeviceMetricHistorySample(date: start.addingTimeInterval(17), value: 0.25),
                         DeviceMetricHistorySample(date: start.addingTimeInterval(100), value: 0.8)]
        chart.selectedTimeRange = DateInterval(start: start, duration: 100)
        chart.unit = "%"
        func move(_ point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: chart.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            chart.mouseMoved(with: event)
        }
        try move(NSPoint(x: chart.plotRect.minX + chart.plotRect.width * 0.2, y: chart.plotRect.midY))
        let hover = try XCTUnwrap(chart.hoverSnapshot)
        XCTAssertEqual(hover.sample, chart.samples[1])
        XCTAssertEqual(hover.valueText, "25.00%")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(hover.timeText, formatter.string(from: start.addingTimeInterval(20)))
        XCTAssertEqual(hover.point.x, chart.plotPoints(in: chart.plotRect)[1].x, accuracy: 0.001)
        XCTAssertEqual(hover.point.y, chart.plotPoints(in: chart.plotRect)[1].y, accuracy: 0.001)
        XCTAssertEqual(hover.guideX, chart.plotRect.minX + chart.plotRect.width * 0.2, accuracy: 0.001)
        XCTAssertNotEqual(hover.guideX, hover.point.x, accuracy: 0.001)
        try move(NSPoint(x: chart.plotRect.maxX - 1, y: chart.plotRect.midY))
        XCTAssertEqual(chart.hoverSnapshot?.sample, chart.samples.last)
        try move(NSPoint(x: 2, y: chart.plotRect.midY))
        XCTAssertNil(chart.hoverSnapshot)
        try move(NSPoint(x: chart.plotRect.midX, y: chart.plotRect.midY))
        chart.samples = []
        XCTAssertNil(chart.hoverSnapshot)
    }

    func testHistoryHoverUsesAdaptiveUnitsAndNeverChangesExport() throws {
        let chart = DeviceMetricHistoryChartView(frame: NSRect(x: 0, y: 0, width: 580, height: 270))
        let window = NSWindow(contentRect: chart.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chart
        defer { window.close() }
        chart.maximumValue = 2 * 1_048_576
        chart.samples = [DeviceMetricHistorySample(date: Date(), value: 2 * 1_048_576)]
        let point = chart.convert(NSPoint(x: chart.plotRect.midX, y: chart.plotRect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        func exportPixels() throws -> Data {
            let image = NSImage(size: chart.bounds.size)
            image.lockFocus()
            NSColor.white.setFill(); chart.bounds.fill()
            chart.drawExport(in: chart.bounds)
            image.unlockFocus()
            return try XCTUnwrap(image.tiffRepresentation)
        }
        for (unit, expected) in [("B/s", "2.0 MB/s"), ("B", "2.0 MB")] {
            chart.unit = unit
            chart.clearHover()
            let before = try exportPixels()
            chart.mouseMoved(with: event)
            XCTAssertEqual(chart.hoverSnapshot?.valueText, expected)
            XCTAssertEqual(try exportPixels(), before)
            chart.isHoverEnabled = false
            XCTAssertNil(chart.hoverSnapshot)
            chart.isHoverEnabled = true
        }
    }

    func testHistoryDetailSupportsAdjustableTwoSidedRange() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<11).map {
            DeviceMetricHistorySample(date: base.addingTimeInterval(Double($0) * 3600), value: Double($0))
        }
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "网络 I/O",
            samples: samples,
            accentColor: .systemOrange,
            unit: "B/s",
            deviceName: "switch-a",
            deviceAddress: "10.211.55.6"
        )
        controller.loadView()
        controller.setRangeForTesting(lower: 0.2, upper: 0.7)

        XCTAssertEqual(controller.selectedRangeForTesting.lower, 0.2, accuracy: 0.01)
        XCTAssertEqual(controller.selectedRangeForTesting.upper, 0.7, accuracy: 0.01)
        XCTAssertLessThan(controller.visibleSamplesForTesting.count, samples.count)
        XCTAssertNotNil(controller.exportPNGDataForTesting())

        controller.setRangeForTesting(lower: 0.8, upper: 0.9)
        XCTAssertEqual(controller.selectedRangeForTesting.lower, 0.8, accuracy: 0.001)
        XCTAssertEqual(controller.selectedRangeForTesting.upper, 0.9, accuracy: 0.001)
    }

    func testHistoryChartMatchesPercentAxisAndActualSampleTimes() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: [
                DeviceMetricHistorySample(date: start, value: 0),
                DeviceMetricHistorySample(date: start.addingTimeInterval(3600), value: 0.5),
                DeviceMetricHistorySample(date: start.addingTimeInterval(14400), value: 1)
            ], accentColor: .systemBlue, unit: "%"
        )
        controller.loadView()
        controller.setRangeForTesting(lower: 0, upper: 1)
        let chart = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.chart") as? DeviceMetricHistoryChartView)
        XCTAssertEqual(chart.displayUnit, "%")
        XCTAssertEqual(chart.displayedMaximum, 100)
        let plot = NSRect(x: 20, y: 30, width: 400, height: 200)
        XCTAssertEqual(chart.plotPoints(in: plot), [
            NSPoint(x: 20, y: 30), NSPoint(x: 120, y: 130), NSPoint(x: 420, y: 230)
        ])
    }

    func testHistoryChartAdaptsCapacityAndRateUnitsAndCentersSingleSample() {
        let chart = DeviceMetricHistoryChartView()
        let plot = NSRect(x: 20, y: 30, width: 400, height: 200)
        XCTAssertTrue(chart.plotPoints(in: plot).isEmpty)
        for (value, prefix) in [(1536.0, "KB"), (2 * 1_048_576.0, "MB"), (3 * 1_073_741_824.0, "GB")] {
            chart.maximumValue = value
            chart.samples = [DeviceMetricHistorySample(date: Date(), value: value)]
            chart.unit = "B/s"
            XCTAssertEqual(chart.displayUnit, prefix + "/s")
            chart.unit = "B"
            XCTAssertEqual(chart.displayUnit, prefix)
            XCTAssertLessThan(chart.displayedMaximum, 1024)
            XCTAssertGreaterThanOrEqual(chart.displayedMaximum, 1)
            XCTAssertEqual(chart.plotPoints(in: plot), [NSPoint(x: 220, y: 230)])
        }
    }

    func testHistoryAggregationKeepsPointsWithinTheSelectedTimeAxis() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0...12).map {
            DeviceMetricHistorySample(date: start.addingTimeInterval(Double($0) * 600), value: 0.5)
        }
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: samples, accentColor: .systemBlue, unit: "%"
        )
        controller.loadView()
        let segmented = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.granularity") as? NSSegmentedControl)
        segmented.selectedSegment = 1
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(segmented.action), to: segmented.target, from: segmented))
        // Select minutes 15...105. Hourly aggregates are stamped at minutes
        // 50 and 90, so neither point belongs on an edge of the selected axis.
        controller.setRangeForTesting(lower: 0.125, upper: 0.875)
        let chart = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.chart") as? DeviceMetricHistoryChartView)
        let points = chart.plotPoints(in: NSRect(x: 0, y: 0, width: 900, height: 100))
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(try XCTUnwrap(points.first).x, 350, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(points.last).x, 750, accuracy: 0.001)
        let selected = DateInterval(start: start.addingTimeInterval(900), end: start.addingTimeInterval(6300))
        XCTAssertEqual(chart.timeRange, selected)

        for segment in [0, 2] {
            segmented.selectedSegment = segment
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(segmented.action), to: segmented.target, from: segmented))
            XCTAssertEqual(chart.timeRange, selected)
        }
        // Daily aggregation produces one point, whose actual time stays at
        // minute 60 inside the selected 15...105-minute interval.
        XCTAssertEqual(try XCTUnwrap(chart.plotPoints(in: NSRect(x: 0, y: 0, width: 900, height: 100)).first).x, 450, accuracy: 0.001)
    }

    func testHistoryExportIdentifiesSelectedDatesAcrossYearBoundary() throws {
        let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23)))
        let samples = (0...12).map {
            DeviceMetricHistorySample(date: start.addingTimeInterval(Double($0) * 600), value: 0.5)
        }
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: samples, accentColor: .systemBlue, unit: "%"
        )
        controller.loadView()
        controller.setRangeForTesting(lower: 0.125, upper: 0.875)
        XCTAssertEqual(controller.exportTimeRangeText, "时间范围：2025-12-31 23:15:00 – 2026-01-01 00:45:00 · 按分钟范围显示 · 原始采样")
        controller.updateHistorySamples(samples + [DeviceMetricHistorySample(date: start.addingTimeInterval(10800), value: 0.6)])
        XCTAssertEqual(controller.exportTimeRangeText, "时间范围：2025-12-31 23:15:00 – 2026-01-01 00:45:00 · 按分钟范围显示 · 原始采样")

        controller.updateHistorySamples([])
        let chart = try XCTUnwrap(controller.view.firstSubview(withIdentifier: "Stacio.Metrics.history.chart") as? DeviceMetricHistoryChartView)
        XCTAssertNil(chart.timeRange)
        XCTAssertEqual(controller.exportTimeRangeText, "暂无历史数据")
    }

    func testHistoryExportKeepsUnitsAndBothAxesReadableInLightAndDarkAppearance() throws {
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "网络 I/O",
            samples: [DeviceMetricHistorySample(date: Date(), value: 2 * 1_048_576)],
            accentColor: .systemBlue,
            unit: "B/s"
        )
        controller.loadView()
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = controller.exportPNGDataForTesting()
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(data)))
            let scaleX = Double(bitmap.pixelsWide) / 1600
            let scaleY = Double(bitmap.pixelsHigh) / 900
            // These regions exclude the logo, header, grid and curve. Only
            // label ink can satisfy the contrast check on the white PNG.
            for (label, region) in [
                ("unit", NSRect(x: 125, y: 675, width: 70, height: 28)),
                ("values", NSRect(x: 125, y: 175, width: 70, height: 500)),
                ("time", NSRect(x: 210, y: 158, width: 1200, height: 28))
            ] {
                var darkPixels = 0
                for y in Int((900 - region.maxY) * scaleY)..<Int((900 - region.minY) * scaleY) {
                    for x in Int(region.minX * scaleX)..<Int(region.maxX * scaleX) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           max(color.redComponent, color.greenComponent, color.blueComponent) < 0.6 {
                            darkPixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(darkPixels, 20, "Missing readable \(label) in \(name.rawValue)")
            }
        }
    }

    func testHistoryRefreshKeepsSelectedDatesWhenSampleWindowMoves() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0...12).map {
            DeviceMetricHistorySample(date: base.addingTimeInterval(Double($0) * 3600), value: Double($0))
        }
        let controller = DeviceMetricHistoryDetailViewController(
            resourceTitle: "CPU", samples: Array(samples.prefix(11)), accentColor: .systemBlue
        )
        controller.loadView()
        controller.setRangeForTesting(lower: 0.2, upper: 0.7)
        let selectedDates = controller.rangeTextForTesting
        let selectedSamples = controller.visibleSamplesForTesting
        controller.updateHistorySamples(samples)
        XCTAssertEqual(controller.rangeTextForTesting, selectedDates)
        XCTAssertEqual(controller.visibleSamplesForTesting, selectedSamples)
        controller.updateHistorySamples(Array(samples.dropFirst()))
        XCTAssertEqual(controller.rangeTextForTesting, selectedDates)
        XCTAssertEqual(controller.visibleSamplesForTesting, selectedSamples)
    }
}

private func metricsDashboardRootWidthConstraintCount(in root: NSView) -> Int {
    root.constraints.filter { constraint in
        (constraint.firstItem as? NSView) === root
            && constraint.secondItem == nil
            && (constraint.firstAttribute == .width || constraint.firstAttribute == .height)
    }.count
}

private func metricsDashboardEventually(
    timeout: TimeInterval = 1.0,
    condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

private final class RecordingDeviceMetricsProvider: DeviceMetricsProviding {
    private let snapshot: DeviceMetricsDisplaySnapshot?
    private let error: Error?
    private(set) var refreshCount = 0

    init(snapshot: DeviceMetricsDisplaySnapshot? = nil, error: Error? = nil) {
        self.snapshot = snapshot
        self.error = error
    }

    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        refreshCount += 1
        if let error {
            completion(.failure(error))
            return
        }
        completion(.success(snapshot ?? .sample))
    }
}

private final class SequenceDeviceMetricsProvider: DeviceMetricsProviding {
    private var results: [Result<DeviceMetricsDisplaySnapshot, Error>]
    private(set) var refreshCount = 0

    init(results: [Result<DeviceMetricsDisplaySnapshot, Error>]) {
        self.results = results
    }

    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        refreshCount += 1
        if results.isEmpty {
            completion(.failure(DeviceMetricsTestError.unavailable))
            return
        }
        completion(results.removeFirst())
    }
}

private final class DeviceMetricsForcedHitContainerView: NSView {
    weak var forcedHit: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        forcedHit ?? super.hitTest(point)
    }
}

private final class BackgroundQueueDeviceMetricsProvider: DeviceMetricsProviding {
    private let snapshot: DeviceMetricsDisplaySnapshot
    private(set) var refreshCount = 0

    init(snapshot: DeviceMetricsDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func pollDeviceMetrics(completion: @escaping (Result<DeviceMetricsDisplaySnapshot, Error>) -> Void) {
        refreshCount += 1
        DispatchQueue.global(qos: .utility).async { [snapshot] in
            completion(.success(snapshot))
        }
    }
}

private final class MainThreadUpdateRecorder {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var recordedValues: [Bool] = []

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record() {
        lock.lock()
        recordedValues.append(Thread.isMainThread)
        lock.unlock()
        expectation.fulfill()
    }
}

private enum DeviceMetricsTestError: Error {
    case unavailable
}

private extension DeviceMetricsDisplaySnapshot {
    static let sample = DeviceMetricsDisplaySnapshot(
        cpuUsage: 0.42,
        cpuCoreUsages: sampleCPUCoreUsages,
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 5_368_709_120, totalBytes: 17_179_869_184),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens160", receiveBytesPerSecond: 12_582_912, transmitBytesPerSecond: 1_572_864)
        ],
        disks: [
            DeviceDiskDisplayUsage(mountPath: "/", usedBytes: 12_000_000_000, totalBytes: 96_000_000_000),
            DeviceDiskDisplayUsage(mountPath: "/data", usedBytes: 78_000_000_000, totalBytes: 100_000_000_000)
        ],
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 10_485_760, writeBytesPerSecond: 1_048_576)
    )

    static let dense = DeviceMetricsDisplaySnapshot(
        cpuUsage: 0.03,
        cpuCoreUsages: sampleCPUCoreUsages,
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 788_600_000, totalBytes: 15_100_000_000),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens160", receiveBytesPerSecond: 1_536, transmitBytesPerSecond: 2_662),
            DeviceNetworkDisplayRate(interfaceName: "br-e76d70614a3c", receiveBytesPerSecond: 0, transmitBytesPerSecond: 0),
            DeviceNetworkDisplayRate(interfaceName: "docker0", receiveBytesPerSecond: 0, transmitBytesPerSecond: 0),
            DeviceNetworkDisplayRate(interfaceName: "veth-extra", receiveBytesPerSecond: 32, transmitBytesPerSecond: 64)
        ],
        disks: [
            DeviceDiskDisplayUsage(mountPath: "/", usedBytes: 11_900_000_000, totalBytes: 95_900_000_000),
            DeviceDiskDisplayUsage(mountPath: "/data", usedBytes: 1_800_000_000, totalBytes: 97_900_000_000),
            DeviceDiskDisplayUsage(mountPath: "/boot", usedBytes: 238_300_000, totalBytes: 1_900_000_000),
            DeviceDiskDisplayUsage(mountPath: "/var/lib/docker", usedBytes: 31_000_000_000, totalBytes: 80_000_000_000),
            DeviceDiskDisplayUsage(mountPath: "/srv/archive", usedBytes: 71_000_000_000, totalBytes: 100_000_000_000),
            DeviceDiskDisplayUsage(mountPath: "/mnt/backup", usedBytes: 180_000_000_000, totalBytes: 200_000_000_000)
        ],
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 1_536, writeBytesPerSecond: 2_662)
    )

    static let initialDense = DeviceMetricsDisplaySnapshot(
        cpuUsage: nil,
        cpuCoreUsages: sampleCPUCoreUsages.map { DeviceCPUCoreDisplayUsage(index: $0.index, usage: nil) },
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 788_600_000, totalBytes: 15_100_000_000),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens160", receiveBytesPerSecond: 1_536, transmitBytesPerSecond: 2_662)
        ],
        disks: dense.disks,
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 0, writeBytesPerSecond: 0)
    )

    static let containerOverlayNetworks = DeviceMetricsDisplaySnapshot(
        cpuUsage: 0.08,
        cpuCoreUsages: sampleCPUCoreUsages,
        system: sampleSystemInfo,
        memory: DeviceMemoryDisplayUsage(usedBytes: 1_200_000_000, totalBytes: 8_000_000_000),
        networks: [
            DeviceNetworkDisplayRate(interfaceName: "ens192", receiveBytesPerSecond: 2_048, transmitBytesPerSecond: 4_096),
            DeviceNetworkDisplayRate(interfaceName: "cni0", receiveBytesPerSecond: 8_192, transmitBytesPerSecond: 16_384),
            DeviceNetworkDisplayRate(interfaceName: "cali1234", receiveBytesPerSecond: 16_384, transmitBytesPerSecond: 32_768),
            DeviceNetworkDisplayRate(interfaceName: "flannel.1", receiveBytesPerSecond: 32_768, transmitBytesPerSecond: 65_536),
            DeviceNetworkDisplayRate(interfaceName: "ovn-k8s-mp0", receiveBytesPerSecond: 4_096, transmitBytesPerSecond: 8_192),
            DeviceNetworkDisplayRate(interfaceName: "tailscale0", receiveBytesPerSecond: 1_024, transmitBytesPerSecond: 2_048)
        ],
        disks: sample.disks,
        diskIO: DeviceDiskIODisplayRate(readBytesPerSecond: 2_048, writeBytesPerSecond: 4_096)
    )

    func with(cpuUsage: Double?) -> DeviceMetricsDisplaySnapshot {
        DeviceMetricsDisplaySnapshot(
            cpuUsage: cpuUsage,
            cpuCoreUsages: cpuCoreUsages,
            system: system,
            memory: memory,
            networks: networks,
            disks: disks,
            diskIO: diskIO
        )
    }

    func with(disks: [DeviceDiskDisplayUsage]) -> DeviceMetricsDisplaySnapshot {
        DeviceMetricsDisplaySnapshot(
            cpuUsage: cpuUsage,
            cpuCoreUsages: cpuCoreUsages,
            system: system,
            memory: memory,
            networks: networks,
            disks: disks,
            diskIO: diskIO
        )
    }

    private static let sampleCPUCoreUsages: [DeviceCPUCoreDisplayUsage] = [
        0.182,
        0.182,
        0.091,
        0.048,
        0.136,
        0.087,
        0.227,
        0.227
    ].enumerated().map { index, usage in
        DeviceCPUCoreDisplayUsage(index: index, usage: usage)
    }

    private static let sampleSystemInfo = DeviceSystemDisplayInfo(
        hostname: "worker-01",
        currentUser: "deploy",
        architecture: "x86_64",
        operatingSystem: "Ubuntu 25.10",
        uptimeText: "14天",
        kernelVersion: "6.8.0-64-generic",
        cpuModel: "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"
    )
}

private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
