import AppKit

@main
struct InventoryChecks {
    private static func verifyProcessCPUIntervals() throws {
        let values = DeviceMetricsInventoryParser.processes("42 1 root R 600 2 4096 8192 00:20 java worker")
        precondition(values.count == 1 && values[0].cpuPercent == 600)
        func sample(total: UInt64 = 1000, user: UInt64 = 100, system: UInt64 = 10,
                    start: UInt64 = 20, boot: UInt64 = 100, cores: String = "cpu0,cpu1,cpu2,cpu3", row: Bool = true) -> String {
            "__STACIO_PROCESS_CPU_COUNTERS__\ncpu \(total) \(cores.split(separator: ",").count) \(boot) \(cores)\n"
                + (row ? "42 \(start) \(user) \(system)\n" : "") + "__STACIO_PROCESS_CPU_COUNTERS_END__\n"
        }
        func next(_ sampler: ManagedProcessCPUSampler, _ output: String) -> ManagedProcessInfo {
            sampler.apply(output, to: values, request: sampler.beginRequest())[0]
        }
        let sampler = ManagedProcessCPUSampler()
        precondition(!next(sampler, sample()).hasCPUUsage, "first sample must not publish lifetime ps CPU")
        let busy = next(sampler, sample(total: 1400, user: 304, system: 20))
        precondition(busy.hasCPUUsage && abs(busy.cpuPercent - 53.5) < 0.001)
        let idle = next(sampler, sample(total: 1800, user: 304, system: 20))
        precondition(idle.hasCPUUsage && idle.cpuPercent == 0)
        precondition(!next(sampler, sample(total: 2200, user: 904, system: 20)).hasCPUUsage, "150% of host capacity must be rejected")
        precondition(!next(sampler, sample(total: 2600, user: 10, start: 30)).hasCPUUsage, "PID reuse must establish a new baseline")
        precondition(next(sampler, sample(total: 3000, user: 110, start: 30)).cpuPercent == 25)
        precondition(!next(sampler, sample(total: 3400, user: 110, system: 5, start: 30)).hasCPUUsage, "counter rollback")
        precondition(!next(sampler, sample(total: 100, user: 1, boot: 200)).hasCPUUsage, "reboot")
        precondition(!next(sampler, sample(total: 500, user: 2, boot: 200, cores: "cpu0,cpu1,cpu2,cpu4")).hasCPUUsage, "CPU identity change")
        precondition(!next(sampler, sample(total: 900, user: 3, boot: 200, cores: "cpu0,cpu1")).hasCPUUsage, "CPU count change")
        precondition(!next(sampler, sample(total: 1300, user: 4, boot: 200, cores: "cpu0,cpu1", row: false)).hasCPUUsage, "missing PID")
        precondition(!next(sampler, "").hasCPUUsage, "unsupported counters must not reuse ps percentage")
        precondition(!next(sampler, sample(total: 1400)).hasCPUUsage, "missing counter block clears the baseline")
        precondition(!next(sampler, sample(total: 1400, user: 200)).hasCPUUsage, "zero time delta")
        precondition(!next(sampler, sample(total: 1000, user: 300)).hasCPUUsage, "aggregate counter rollback")

        let concurrent = ManagedProcessCPUSampler()
        _ = next(concurrent, sample())
        let olderRequest = concurrent.beginRequest(), newerRequest = concurrent.beginRequest()
        precondition(concurrent.apply(sample(total: 1400, user: 300), to: values, request: newerRequest)[0].cpuPercent == 50)
        precondition(!concurrent.apply(sample(total: 1200, user: 200), to: values, request: olderRequest)[0].hasCPUUsage)
        precondition(next(concurrent, sample(total: 1800, user: 400)).cpuPercent == 25, "stale completion rewound the baseline")
        concurrent.fail(request: olderRequest)
        precondition(next(concurrent, sample(total: 2200, user: 500)).cpuPercent == 25, "old failure cleared a newer baseline")
        concurrent.fail(request: concurrent.beginRequest())
        precondition(!next(concurrent, sample(total: 2600, user: 600)).hasCPUUsage, "failed request must clear the baseline")
        let anotherSession = ManagedProcessCPUSampler()
        precondition(!next(anotherSession, sample(total: 1800, user: 400)).hasCPUUsage, "new sessions cannot borrow another host baseline")

        let overflowing = ManagedProcessCPUSampler()
        _ = next(overflowing, sample(user: 0, system: 0))
        precondition(!next(overflowing, sample(total: 1400, user: UInt64.max, system: UInt64.max)).hasCPUUsage)
        for broken in [sample().replacingOccurrences(of: "42 20 100 10", with: "42 20 100 10\n42 20 100 10"),
                       sample().replacingOccurrences(of: "cpu3", with: "cpu2"),
                       sample().replacingOccurrences(of: "__STACIO_PROCESS_CPU_COUNTERS_END__", with: "")] {
            precondition(!next(ManagedProcessCPUSampler(), broken).hasCPUUsage)
        }
        precondition(DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_FULL_PS__\n42 1 root R 600 2 4096 8192 00:20 java worker\n" + sample()).count == 1)

        // Execute the actual one-process awk collector against procfs-shaped
        // fixtures, including a comm with spaces and embedded parentheses.
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-process-counters-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let proc = fixture.appendingPathComponent("proc")
        try FileManager.default.createDirectory(at: proc.appendingPathComponent("42"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proc.appendingPathComponent("99"), withIntermediateDirectories: true)
        // guest counters must not be double-counted; first eight fields total 1000.
        try "cpu 100 100 100 100 100 100 100 300 9000 8000\ncpu0 1 1 1 1\ncpu1 1 1 1 1\ncpu2 1 1 1 1\ncpu3 1 1 1 1\nbtime 100\n"
            .write(to: proc.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
        var fields = Array(repeating: "0", count: 22)
        fields[0] = "R"; fields[11] = "100"; fields[12] = "10"; fields[19] = "20"
        try ("42 (java (worker)\n 12) " + fields.joined(separator: " ") + "\n")
            .write(to: proc.appendingPathComponent("42/stat"), atomically: true, encoding: .utf8)
        // A vanished process must not make awk abort the remaining list.
        let ps = fixture.appendingPathComponent("ps")
        try "#!/bin/sh\nprintf '%s\\n' '__STACIO_PROCESS_PID__' '42 1 root R 600 2 4096 8192 00:20 java worker'\n"
            .write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", DeviceMetricsInventoryCommands.processes.replacingOccurrences(of: "/proc/", with: proc.path + "/")]
        process.environment = ["PATH": fixture.path + ":/usr/bin:/bin", "TMPDIR": fixture.path]
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        precondition(process.terminationStatus == 0 && output.contains("cpu 1000 4 100 cpu0,cpu1,cpu2,cpu3\n42 20 100 10\n"), output)
        let collected = ManagedProcessCPUSampler()
        _ = next(collected, output)
        precondition(next(collected, sample(total: 1400, user: 300)).cpuPercent == 50)
    }

    private static func verifyProcessCollectorFallback(command: String) throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-process-source-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let ps = """
        #!/bin/sh
        case "$1" in
          -eww|-eo) printf '%s\\n' '12 1 root S 1 2 3 4 00:01 partial'; exit 1 ;;
          *) printf '%s\\n' 'PID USER VSZ STAT COMMAND' '22 1000 4096 S \(command)' ;;
        esac
        """
        let top = "#!/bin/sh\nprintf '%s\\n' '21 1 root S 2048 0.5 2.5 discarded'\nexit 1\n"
        for (name, contents) in [("ps", ps), ("top", top)] {
            let path = fixture.appendingPathComponent(name)
            try contents.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", DeviceMetricsInventoryCommands.processes]
        process.environment = ["PATH": fixture.path + ":/usr/bin:/bin", "TMPDIR": fixture.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let values = DeviceMetricsInventoryParser.processes(String(decoding: data, as: UTF8.self))
        precondition(values.count == 1 && values[0].pid == 22 && values[0].user == "1000" && values[0].command == command)
    }

    private static func verifyTopCollectorLayouts() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-top-columns-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let ps = fixture.appendingPathComponent("ps")
        try "#!/bin/sh\nexit 1\n".write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ps.path)
        for (header, row, expectedCPU) in [
            ("PID PPID USER STAT VSZ %VSZ CPU COMMAND", "21 1 root S 1356 1% 7 123 --worker", nil),
            ("PID PPID USER STAT VSZ %VSZ COMMAND", "21 1 root S 1356 1% 123 --worker", nil),
            ("PID PPID USER STAT VSZ %VSZ %CPU COMMAND", "21 1 root S 1356 1% 2.5 123 --worker", 2.5),
            ("PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND", "21 1 root S 1356 1% 7 2.5 123 --worker", 2.5)
        ] as [(String, String, Double?)] {
            let top = fixture.appendingPathComponent("top")
            let script = "#!/bin/sh\nprintf '%s\\n' '\(header)' '\(row)'\n"
            try script.write(to: top, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: top.path)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", DeviceMetricsInventoryCommands.processes]
            process.environment = ["PATH": fixture.path + ":/usr/bin:/bin", "TMPDIR": fixture.path]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            let values = DeviceMetricsInventoryParser.processes(String(decoding: data, as: UTF8.self))
            precondition(values.count == 1 && values[0].pid == 21 && values[0].command == "123 --worker")
            precondition(values[0].hasCPUUsage == (expectedCPU != nil) && values[0].cpuPercent == (expectedCPU ?? 0))
            precondition(!values[0].hasMemoryUsage && values[0].memoryPercent == 0 && values[0].virtualBytes == 1_388_544)
        }
        let badPercent = "__STACIO_PROCESS_TOP__\nPID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND\n21 1 root S 1356 1% 7 nan worker"
        precondition(DeviceMetricsInventoryParser.processes(badPercent).isEmpty)
    }

    private static func verifyFixedWidthTopColumns() {
        // Match BusyBox top.c's actual printf layouts: STAT is three
        // characters, VSZ is five, and percentage fields have no separator.
        func percentage(_ tenths: Int) -> String {
            String(format: "%3d.%d", tenths / 10, tenths % 10)
        }
        func header(core: Bool, cpu: Bool) -> String {
            "  PID  PPID USER     STAT   VSZ %VSZ" + (core ? " CPU" : "") + (cpu ? " %CPU" : "") + " COMMAND"
        }
        func row(prefix: String = "   21     1 root    ", state: String = "R  ", vsz: String = " 128m",
                 memory: String, core: Int?, cpu: String?, command: String) -> String {
            prefix + " " + state + "  " + vsz + memory
                + (core.map { String(format: " %3d", $0) } ?? "") + (cpu ?? "") + " " + command
        }
        let command = "123 --worker  --label 'hello world' --path /tmp/测试  "
        for (memory, cpu, core) in [
            (100, 1_000, 7), (1_000, 25, 7), (1_000, 1_000, 7), (999, 999, 7),
            (1_000, 1_000, nil), (1_000, nil, 7), (1_000, nil, nil)
        ] as [(Int, Int?, Int?)] {
            let output = "__STACIO_PROCESS_TOP__\n" + header(core: core != nil, cpu: cpu != nil) + "\n"
                + row(memory: percentage(memory), core: core, cpu: cpu.map(percentage), command: command)
            let values = DeviceMetricsInventoryParser.processes(output)
            precondition(values.count == 1, "BusyBox fixed-width columns lost a process: \(output)")
            let value = values[0]
            precondition(value.pid == 21 && value.parentPID == 1 && value.user == "root" && value.state == "R")
            precondition(value.command == command, "fixed-width parsing changed the command remainder")
            precondition(!value.hasMemoryUsage && value.memoryPercent == 0 && value.virtualBytes == 128 * 1024 * 1024)
            precondition(value.hasCPUUsage == (cpu != nil) && value.cpuPercent == Double(cpu ?? 0) / 10)
        }
        // Integer percentage builds and wide PIDs must not depend on a fixed
        // 20-byte PID/user prefix. New BusyBox versions shorten the user field;
        // older versions can retain all eight displayed username characters.
        for (prefix, user) in [("4194303 4194304 abcd", "abcd"), ("4194303 4194304 abcdefgh", "abcdefgh")] {
            for core in [nil, 127] as [Int?] {
                let output = "__STACIO_PROCESS_TOP__\n" + header(core: core != nil, cpu: true) + "\n"
                    + row(prefix: prefix, state: "SW<", memory: String(format: "%4d%%", 1_000), core: core,
                          cpu: String(format: "%4d%%", 100), command: command)
                let values = DeviceMetricsInventoryParser.processes(output)
                precondition(values.count == 1 && values[0].pid == 4_194_303 && values[0].parentPID == 4_194_304)
                precondition(values[0].user == user && values[0].state == "SW<" && values[0].command == command)
                precondition(!values[0].hasMemoryUsage && values[0].memoryPercent == 0 && values[0].cpuPercent == 100 && values[0].hasCPUUsage)
            }
        }
        let malformed = [
            row(memory: "  nan", core: 7, cpu: percentage(1_000), command: command),
            row(memory: percentage(1_000), core: 7, cpu: "  nan", command: command),
            row(vsz: " nope", memory: percentage(1_000), core: 7, cpu: percentage(1_000), command: command),
            row(memory: percentage(100), core: -1, cpu: percentage(25), command: command)
        ]
        for line in malformed {
            let output = "__STACIO_PROCESS_TOP__\n" + header(core: true, cpu: true) + "\n" + line
            precondition(DeviceMetricsInventoryParser.processes(output).isEmpty, "malformed fixed-width metrics were accepted: \(line)")
        }
    }

    private static func verifyLsofProtocolColumns() {
        for (command, user) in [("tcp", "root"), ("udp", "root"), ("worker", "tcp"), ("worker", "udp"), ("TCP", "udp"), ("udp", "TCP")] {
            for (type, address) in [("IPv4", "127.0.0.1"), ("IPv6", "[::1]")] {
                for proto in ["TCP", "UDP"] {
                    let row = "\(command) 42 \(user) 3u \(type) 0x123 0t0 \(proto) \(address):8080" + (proto == "TCP" ? " (LISTEN)" : "")
                    let values = DeviceMetricsInventoryParser.ports(row)
                    precondition(values.count == 1, "lsof COMMAND/USER was mistaken for a protocol: \(row)")
                    precondition(values[0].pid == 42 && values[0].port == 8080 && values[0].processName == command)
                    precondition(values[0].protocolName == proto + (type == "IPv6" ? "6" : ""))
                    precondition(values[0].address == (type == "IPv6" ? "::1" : "127.0.0.1"))
                    let connected = "\(command) 42 \(user) 3u \(type) 123 0t0 \(proto) \(address):8080->\(address):8081" + (proto == "TCP" ? " (ESTABLISHED)" : "")
                    precondition(DeviceMetricsInventoryParser.ports(connected).isEmpty, "connected client became a listener")
                }
            }
        }
        precondition(DeviceMetricsInventoryParser.ports("""
        tcp 42 udp 3u REG 123 0t0 123 /tmp/TCP:8080 (LISTEN)
        worker 42 tcp 3u IPv4 123 0t0 ICMP *:8080
        worker 42 udp 3u IPv6 123 0t0 TCP [::1]:8080 (ESTABLISHED)
        worker 42 root 3u IPv4 123 0t0 TCP *:65536 (LISTEN)
        """).isEmpty)
    }

    private static func verifyProcessCollectorFormatHandshake() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-process-handshake-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let ps = """
        #!/bin/sh
        printf '%s\\n' "ps $*" >> "$STACIO_TRACE"
        case "$STACIO_PS_MODE" in
          ignore) printf '%s\\n' '21 1000 4096 S ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4'; exit 0 ;;
          ignore_header) printf '%s\\n' 'PID USER VSZ STAT COMMAND' '21 1000 4096 S ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4'; exit 0 ;;
          fail) printf '%s\\n' '999 root 1 S partial'; exit 42 ;;
        esac
        for argument do
          case "$argument" in pid=*) header=${argument#pid=} ;; esac
        done
        [ -n "$header" ] || exit 43
        printf '   %s     \\n' "$header"
        if [ "$STACIO_PS_MODE" = partial ] && [ "$1" = -eww ]; then
          printf '%s\\n' '999 1 root S 1 2 3 4 00:01 partial'
          exit 42
        fi
        if [ "$STACIO_PS_MODE" = invalid ]; then
          printf '%s\\n' '23 1 1000 S nan 2 1 1 00:01 invalid'
        else
          printf '%s\\n' '23 1 1000 S 12.5 2.5 4096 8192 00:01 ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4'
        fi
        """
        let top = """
        #!/bin/sh
        printf '%s\\n' "top $*" >> "$STACIO_TRACE"
        if [ "$STACIO_TOP_FAIL" = 1 ]; then printf '%s\\n' '999 1 root S 2048 1 2 partial'; exit 44; fi
        printf '%s\\n' 'PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND' '22 1 root R 4096 1% 7 9.5 /sbin/worker'
        """
        for (name, contents) in [("ps", ps), ("top", top)] {
            let path = fixture.appendingPathComponent(name)
            try contents.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        for (mode, failTop, expectedPID, expectedStatus, expectedCalls) in [
            ("ignore", false, 22, 0, 3),
            ("ignore_header", false, 22, 0, 3),
            ("ignore", true, 21, 0, 4),
            ("full", false, 23, 0, 1),
            ("partial", false, 23, 0, 2),
            ("invalid", false, nil, 0, 1),
            ("fail", true, nil, 42, 5)
        ] as [(String, Bool, UInt32?, Int32, Int)] {
            let trace = fixture.appendingPathComponent("trace")
            try "".write(to: trace, atomically: true, encoding: .utf8)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", DeviceMetricsInventoryCommands.processes]
            process.environment = ["PATH": fixture.path + ":/usr/bin:/bin", "TMPDIR": fixture.path,
                                   "STACIO_TRACE": trace.path, "STACIO_PS_MODE": mode, "STACIO_TOP_FAIL": failTop ? "1" : "0"]
            process.standardOutput = output
            try process.run()
            let raw = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            precondition(process.terminationStatus == expectedStatus)
            let values = DeviceMetricsInventoryParser.processes(raw)
            if expectedStatus == 0 {
                precondition(values.map(\.pid) == expectedPID.map { [$0] } ?? [])
                if let value = values.first {
                    precondition(value.hasCPUUsage == (expectedPID != 21))
                    if expectedPID == 21 || expectedPID == 23 {
                        precondition(value.command == "ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4" && value.user == "1000")
                    }
                    if expectedPID == 23 { precondition(value.cpuPercent == 12.5 && value.memoryPercent == 2.5 && value.residentBytes == 4_194_304) }
                }
            }
            if mode == "ignore" || mode == "ignore_header" { precondition(!raw.contains("__STACIO_PROCESS_FULL_PS__")) }
            if mode == "partial" { precondition(!raw.contains("999"), "failed full-ps output leaked into the valid result") }
            let calls = try String(contentsOf: trace, encoding: .utf8).split(whereSeparator: \.isNewline)
            precondition(calls.count == expectedCalls)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
            precondition(!leftovers.contains { $0.hasPrefix("stacio-processes.") })
        }
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let processes = DeviceMetricsInventoryParser.processes("12 1 root Ssl 18.2 1.5 4096 8192 01:20 /usr/bin/java --path hello world\n13 1 me R 2 1 1 2 00:01 ps -eww\n14 1 me T 0 0 0 0 00:01 stopped\n15 1 root S nan 2 1 1 00:01 invalid")
        precondition(processes.count == 3 && !processes[0].isRunning && processes[0].statusLabel == "睡眠")
        precondition(processes[1].isRunning && processes[2].isStopped)
        precondition(processes[0].command == "/usr/bin/java --path hello world" && processes[0].residentBytes == 4_194_304)
        let busyBoxTop = DeviceMetricsInventoryParser.processes("""
        PID   PPID USER     STAT   VSZ %VSZ %CPU COMMAND
        21    1    root     S      2048 0.5 2.5 /usr/sbin/daemon --foreground
        """)
        precondition(busyBoxTop.count == 1 && busyBoxTop[0].pid == 21 && busyBoxTop[0].cpuPercent == 2.5)
        let busyBoxTopWithSuffix = DeviceMetricsInventoryParser.processes("21 1 root S 2k 0.5 2.5 /usr/sbin/daemon")
        precondition(busyBoxTopWithSuffix.count == 1 && busyBoxTopWithSuffix[0].virtualBytes == 2 * 1024)
        let busyBoxTopWithCPUColumn = DeviceMetricsInventoryParser.processes("""
        PID PPID USER STAT VSZ %VSZ CPU %CPU COMMAND
        1 0 root S 1356 1% 0 2% /sbin/procd
        411 1 root R 97.6m 10.0 3 7.0 /sbin/ubusd --foreground
        """)
        precondition(busyBoxTopWithCPUColumn.count == 2)
        precondition(busyBoxTopWithCPUColumn[0].cpuPercent == 2 && !busyBoxTopWithCPUColumn[0].hasMemoryUsage && busyBoxTopWithCPUColumn[0].memoryPercent == 0)
        precondition(busyBoxTopWithCPUColumn[0].command == "/sbin/procd")
        precondition(busyBoxTopWithCPUColumn[1].cpuPercent == 7 && busyBoxTopWithCPUColumn[1].command == "/sbin/ubusd --foreground")
        let busyBoxPS = DeviceMetricsInventoryParser.processes("""
        PID USER VSZ STAT COMMAND
        22 root 4096 S /bin/sh -c worker
        """)
        precondition(busyBoxPS.count == 1 && busyBoxPS[0].pid == 22 && busyBoxPS[0].virtualBytes == 4_194_304)
        let paddedBusyBoxTop = DeviceMetricsInventoryParser.processes("""
          PID  PPID USER     STAT   VSZ %VSZ CPU %CPU COMMAND
            1     0 root     S       1356   1%   0   2% /sbin/procd
          411     1 root     R     97.6m 10.0   3  7.0 /sbin/ubusd --foreground
          PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
           21     1 root     S       2048  0.5  2.5 /usr/sbin/daemon --foreground
        """)
        precondition(paddedBusyBoxTop.count == 3 && paddedBusyBoxTop.map(\.cpuPercent) == [2, 7, 2.5])
        precondition(paddedBusyBoxTop.map(\.state) == ["S", "R", "S"] && paddedBusyBoxTop[1].command == "/sbin/ubusd --foreground")
        let longCommand = "/bin/sh -c worker --one a --two b --three c --four d"
        let longBusyBoxPS = DeviceMetricsInventoryParser.processes(" 22 root 4096 S " + longCommand + "\n 23 S 01:20 " + longCommand)
        precondition(longBusyBoxPS.count == 2 && longBusyBoxPS.allSatisfy { $0.command == longCommand && $0.state == "S" })
        precondition(longBusyBoxPS[0].virtualBytes == 4_194_304 && longBusyBoxPS[1].elapsed == "01:20")
        let numericUserCommand = "ffmpeg -i input.mp4 -ss 00:10 -t 00:20 output.mp4"
        for prefix in ["", "PID USER VSZ STAT COMMAND\n", "__STACIO_PROCESS_PS__\nPID USER VSZ STAT COMMAND\n"] {
            let numericUserPS = DeviceMetricsInventoryParser.processes(prefix + "22 1000 4096 S " + numericUserCommand)
            precondition(numericUserPS.count == 1 && numericUserPS[0].user == "1000")
            precondition(numericUserPS[0].command == numericUserCommand && numericUserPS[0].virtualBytes == 4_194_304)
        }
        // The identical tokens can mean invalid full-ps metrics or a valid
        // BusyBox command. The collector/header decides, never command args.
        let ambiguousRow = "15 1 1000 S nan 2 1 1 00:01 invalid"
        precondition(DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_FULL_PS__\n" + ambiguousRow).isEmpty)
        let ambiguousPS = DeviceMetricsInventoryParser.processes("__STACIO_PROCESS_PS__\nPID USER VSZ STAT COMMAND\n" + ambiguousRow)
        precondition(ambiguousPS.first?.command == "nan 2 1 1 00:01 invalid")
        let failedCollectorOutput = "__STACIO_PROCESS_FULL_PS__\n12 1 root S 1 2 3 4 00:01 partial\n__STACIO_PROCESS_TOP__\n21 1 root S 2048 0.5 2.5 discarded\n__STACIO_PROCESS_PS__\nPID USER VSZ STAT COMMAND\n22 1000 4096 S " + numericUserCommand
        precondition(DeviceMetricsInventoryParser.processes(failedCollectorOutput).map(\.pid) == [22])
        try verifyProcessCollectorFallback(command: numericUserCommand)
        try verifyTopCollectorLayouts()
        try verifyProcessCPUIntervals()
        verifyFixedWidthTopColumns()
        try verifyProcessCollectorFormatHandshake()
        precondition(longBusyBoxPS.allSatisfy { !$0.hasCPUUsage })
        precondition(DeviceMetricsInventoryParser.processes("15 1 1000 S nan 2 1 1 00:01 invalid\n16 1 root S 2 nan 1 1 00:01 invalid\n17 not-a-state 00:01 invalid").isEmpty)
        let oversizedProcesses = DeviceMetricsInventoryParser.processes("""
        12 1 root S 1 2 18446744073709551615 8192 00:01 worker
        13 1 root S 1 2 8192 18446744073709551616 00:01 worker
        14 root 18446744073709551615 S worker
        15 1 root S 18446744073709551616 1 2 worker
        16 root 1e309 S worker
        """)
        precondition(oversizedProcesses.isEmpty)
        let services = DeviceMetricsInventoryParser.services("""
        __STACIO_SYSTEM__
        ● ups.service loaded failed failed UPS monitor
        ● account.service not-found inactive dead account.service
        api.service loaded active running API system
        __STACIO_USER__
        api.service loaded active running Duplicate user service
        user.service loaded inactive dead User service
        """)
        precondition(services.count == 4 && services.first?.name == "ups.service")
        precondition(services.first { $0.name == "api.service" }?.scope == "system")
        precondition(services.first { $0.name == "user.service" }?.scope == "user")
        let containers = DeviceMetricsInventoryParser.containers("""
        {"ID":"abcdef123456","Names":"api","Image":"my/api","State":"running","Status":"Up 2 days"}
        {"ID":"abcdef123457","Names":"paused","Image":"my/db","State":"running","Status":"Up 2 days (Paused)"}
        {"Id":"abcdef123458","Names":["worker"],"Image":"my/worker","State":"exited","Status":"Exited (0)"}
        """)
        precondition(containers.count == 3 && containers[0].isRunning)
        precondition(containers[1].isPaused && !containers[1].isRunning && !containers[2].isRunning)
        let ports = DeviceMetricsInventoryParser.ports("""
        tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=99,fd=4))
        udp UNCONN 0 0 [::]:111 [::]:*
        tcp6 0 0 :::8080 :::* LISTEN 123/java
        """)
        precondition(ports.count == 3 && ports[0].pid == 99 && ports[1].protocolName == "UDP6" && ports[2].pid == 123)
        precondition(ports[2].processName == "java")
        let ownerFormats = DeviceMetricsInventoryParser.ports("""
        __STACIO_SS__
        tcp LISTEN 0 128 0.0.0.0:14410 0.0.0.0:* users:(("legacy worker",501,4),("legacy child",502,5))
        tcp LISTEN 0 128 0.0.0.0:14411 0.0.0.0:* users:(("",pid=503,fd=4))
        tcp LISTEN 0 128 0.0.0.0:14412 0.0.0.0:* users:(("zero",pid=0,fd=4))
        tcp LISTEN 0 128 0.0.0.0:14413 0.0.0.0:* users:(("overflow",pid=4294967296,fd=4))
        tcp LISTEN 0 128 0.0.0.0:14414 0.0.0.0:* users:(("missing fd",504))
        tcp LISTEN 0 128 0.0.0.0:14415 0.0.0.0:* ("not users",505,4)
        tcp LISTEN 0 128 0.0.0.0:14416 0.0.0.0:* users:(("zero",0,4),("valid",506,5))
        __STACIO_NETSTAT__
        tcp 0 0 0.0.0.0:14420 0.0.0.0:* LISTEN 601/worker with spaces
        udp 0 0 0.0.0.0:14421 0.0.0.0:* 602/dns worker with spaces
        tcp 0 0 0.0.0.0:14422 0.0.0.0:* LISTEN 603/worker users:(("not an owner",pid=999,fd=4))
        tcp 0 0 0.0.0.0:14423 0.0.0.0:* LISTEN 0/zero
        udp 0 0 0.0.0.0:14424 0.0.0.0:* - command 123/not-an-owner
        __STACIO_LSOF__
        kernel 0 root 3u IPv4 0x1 0t0 TCP *:14425 (LISTEN)
        """)
        precondition(ownerFormats.filter { $0.port == 14410 }.compactMap(\.pid).sorted() == [501, 502])
        precondition(ownerFormats.first { $0.pid == 501 }?.processName == "legacy worker")
        precondition(ownerFormats.first { $0.port == 14411 }?.pid == 503
                     && ownerFormats.first { $0.port == 14411 }?.processName == "")
        precondition(ownerFormats.filter { [14412, 14413, 14414, 14415, 14423, 14424, 14425].contains($0.port) }
            .allSatisfy { $0.pid == nil && $0.processName.isEmpty }, "Invalid or misplaced owner identity was associated")
        precondition(ownerFormats.filter { $0.port == 14416 }.count == 1
                     && ownerFormats.first { $0.port == 14416 }?.pid == 506)
        precondition(ownerFormats.first { $0.port == 14420 }?.processName == "worker with spaces")
        precondition(ownerFormats.first { $0.port == 14421 }?.processName == "dns worker with spaces")
        precondition(ownerFormats.first { $0.port == 14422 }?.pid == 603
                     && ownerFormats.first { $0.port == 14422 }?.processName == "worker users:((\"not an owner\",pid=999,fd=4))")
        let namedOwner = "tcp LISTEN 0 128 0.0.0.0:14430 0.0.0.0:* users:((\"known worker\",pid=701,fd=4))"
        let pidOnlyOwner = """
        __STACIO_NETSTAT__
        Proto Recv-Q Send-Q Local Address Foreign Address (state) rhiwat shiwat pid epid
        tcp4 0 0 *.14430 *.* LISTEN 131072 131072 701 0
        """
        for ownerOutput in [namedOwner + "\n" + pidOnlyOwner, pidOnlyOwner + "\n__STACIO_SS__\n" + namedOwner] {
            let mergedOwner = DeviceMetricsInventoryParser.ports(ownerOutput)
            precondition(mergedOwner.count == 1 && mergedOwner[0].pid == 701
                         && mergedOwner[0].processName == "known worker", "A PID-only duplicate erased its known process name")
        }
        let wildcard = DeviceMetricsInventoryParser.ports("__STACIO_IPV6__\ntcp LISTEN 0 128 *:22 *:*")
        precondition(wildcard.first?.protocolName == "TCP6")
        let mergedPorts = DeviceMetricsInventoryParser.ports("""
        __STACIO_PORTS_BEGIN__
        __STACIO_SS__
        tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:(("api",pid=11,fd=3),("api-worker",pid=12,fd=4))
        __STACIO_LSOF__
        api 11 root 3u IPv4 0x1 0t0 TCP *:8080 (LISTEN)
        __STACIO_PORTS_END__
        """)
        precondition(mergedPorts.contains { $0.pid == 11 } && mergedPorts.contains { $0.pid == 12 })
        precondition(mergedPorts.contains { $0.processName == "api" && $0.port == 8080 })
        let lsofOnly = DeviceMetricsInventoryParser.ports("""
        __STACIO_PORTS_BEGIN__
        __STACIO_LSOF__
        api 11 root 3u IPv4 0x1 0t0 TCP *:8080 (LISTEN)
        __STACIO_PORTS_END__
        """)
        precondition(lsofOnly.count == 1 && lsofOnly[0].pid == 11 && lsofOnly[0].processName == "api")
        let lsofConnected = DeviceMetricsInventoryParser.ports("""
        __STACIO_PORTS_BEGIN__
        __STACIO_LSOF__
        api 11 root 3u IPv4 0x1 0t0 TCP 10.0.0.1:8080->10.0.0.2:50000 (ESTABLISHED)
        __STACIO_PORTS_END__
        """)
        precondition(lsofConnected.isEmpty)
        verifyLsofProtocolColumns()
        precondition(DeviceMetricsInventoryParser.ports("tcp46 0 0 *.443 *.* LISTEN").first?.protocolName == "TCP6")
        let udpListeners = DeviceMetricsInventoryParser.ports("""
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
        precondition(udpListeners.count == 5 && udpListeners.allSatisfy { $0.port < 10_000 })
        precondition(udpListeners.filter { $0.port == 111 }.map(\.pid).compactMap { $0 }.sorted() == [11, 12])
        precondition(udpListeners.contains { $0.protocolName == "UDP6" && $0.port == 5353 })
        let familyPorts = DeviceMetricsInventoryParser.ports("""
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
        precondition(familyPorts.count == 6)
        precondition(familyPorts.filter { $0.protocolName == "TCP6" }.compactMap(\.pid).sorted() == [99, 100])
        precondition(familyPorts.filter { $0.protocolName == "UDP6" }.compactMap(\.pid).sorted() == [99, 100])
        precondition(familyPorts.first { $0.port == 443 }?.protocolName == "TCP")
        precondition(familyPorts.filter { $0.port == 8080 && $0.protocolName == "TCP" }.count == 1)
        let largePortInput = (1_024..<61_024).map { "tcp LISTEN 0 128 0.0.0.0:\($0) 0.0.0.0:*" }.joined(separator: "\n")
        let largePortStart = Date()
        let largePorts = DeviceMetricsInventoryParser.ports(largePortInput)
        let largePortDuration = Date().timeIntervalSince(largePortStart)
        precondition(largePorts.count == 60_000 && largePorts.first?.port == 1_024 && largePorts.last?.port == 61_023)
        print("Port parser: 60000 anonymous listeners in \(String(format: "%.3f", largePortDuration))s")
        let boundedCommand = DeviceMetricsInventoryCommands.boundedRemoteCommand("sleep 30")
        precondition(boundedCommand.contains("sleep 25") && boundedCommand.contains("__stacio_watchdog_pid"))
        precondition(boundedCommand.contains("mktemp") && boundedCommand.contains("umask 077"))
        precondition(boundedCommand.contains("ulimit -f 32768") && boundedCommand.contains("setsid"))
        precondition(boundedCommand.contains("/proc/$1/task/$1/children") && boundedCommand.contains("kill -KILL \"-$1\""))
        let commandProcess = Process()
        let commandOutput = Pipe()
        commandProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        commandProcess.arguments = ["-c", DeviceMetricsInventoryCommands.boundedRemoteCommand("printf stacio-ok")]
        commandProcess.standardOutput = commandOutput
        commandProcess.standardError = commandOutput
        try commandProcess.run()
        commandProcess.waitUntilExit()
        let commandText = String(decoding: commandOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        precondition(commandProcess.terminationStatus == 0 && commandText == "stacio-ok")
        func rejects(_ operation: () throws -> String) {
            do { _ = try operation(); preconditionFailure("Unsafe command was accepted") } catch { }
        }
        rejects { try DeviceMetricsInventoryCommands.container(.stop, id: "abc; touch /tmp/unsafe", engine: "docker") }
        rejects { try DeviceMetricsInventoryCommands.service(.stop, name: "x.service; reboot", scope: "system") }
        rejects { try DeviceMetricsInventoryCommands.process(.terminate, pid: 1) }
        rejects { try DeviceMetricsInventoryCommands.process(.renice(-21), pid: 99) }
        let forceCommand = try DeviceMetricsInventoryCommands.process(.forceTerminate, pid: 99)
        precondition(forceCommand == "kill -KILL 99")
        let command = try DeviceMetricsInventoryCommands.service(.start, name: "worker@a.service", scope: "user")
        precondition(command == "systemctl --user --no-ask-password start -- 'worker@a.service'")

        let panel = DeviceMetricsInventoryPanel(segment: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 540))
        window.contentView = root
        root.addSubview(panel)
        NSLayoutConstraint.activate([panel.topAnchor.constraint(equalTo: root.topAnchor), panel.leadingAnchor.constraint(equalTo: root.leadingAnchor), panel.trailingAnchor.constraint(equalTo: root.trailingAnchor)])
        var rows: [DeviceMetricsInventoryPanel.Row] = (2..<10002).map { (i: Int) -> DeviceMetricsInventoryPanel.Row in
            let running = i % 2 == 0
            return DeviceMetricsInventoryPanel.Row(id: String(i), title: "worker \(i)", subtitle: "root · PID \(i)", badge: running ? "运行中" : "睡眠", tone: .normal, filter: running ? 1 : 0, search: "worker \(i)", cpu: Double(i), memory: Double(i % 100), pid: UInt32(i))
        }
        let start = Date()
        panel.update(rows)
        root.layoutSubtreeIfNeeded()
        precondition(panel.table.numberOfRows == 10000)
        let countRect = panel.countLabel.convert(panel.countLabel.bounds, to: root)
        let sortRect = panel.sortControl.convert(panel.sortControl.bounds, to: root)
        let filterRect = panel.filterControl.convert(panel.filterControl.bounds, to: root)
        let searchRect = panel.searchField.convert(panel.searchField.bounds, to: root)
        precondition(abs(countRect.midY - sortRect.midY) < 2 && countRect.maxX <= sortRect.minX)
        precondition(filterRect.maxY < searchRect.minY && countRect.maxY < filterRect.minY)
        precondition(panel.filterControl.width(forSegment: 1) >= 50)
        let sortLabels = ["CPU", "内存", "PID", "命令", "用户"]
        let sortFont = panel.sortControl.font ?? NSFont.systemFont(ofSize: 11)
        for (index, label) in sortLabels.enumerated() {
            let expectedWidth = ceil(([label + " ↑", label + " ↓"] as [NSString])
                .map { $0.size(withAttributes: [.font: sortFont]).width }.max() ?? 0) + 14
            precondition(panel.sortControl.width(forSegment: index) >= expectedWidth)
        }
        precondition(panel.sortControl.label(forSegment: 0) == "CPU ↓")
        // NSTableView must instantiate only the viewport, not all ten thousand records.
        let visible = panel.table.rows(in: panel.table.visibleRect)
        precondition(visible.length < 30 && visible.length > 0)
        precondition(panel.visibleRows.first?.pid == 10001)
        panel.sortControl.sendAction(panel.sortControl.action, to: panel.sortControl.target)
        precondition(panel.visibleRows.first?.pid == 2)
        precondition(panel.sortControl.label(forSegment: 0) == "CPU ↑")
        panel.filterControl.selectedSegment = 1
        panel.filterControl.sendAction(panel.filterControl.action, to: panel.filterControl.target)
        precondition(panel.visibleRows.count == 5000 && panel.visibleRows.allSatisfy { $0.filter == 1 })
        panel.searchField.stringValue = "worker 10000"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        precondition(panel.visibleRows.count == 1 && panel.visibleRows[0].pid == 10000)
        let searchIdentity = ObjectIdentifier(panel.searchField)
        rows[0].cpu = 0.2
        panel.update(rows)
        precondition(ObjectIdentifier(panel.searchField) == searchIdentity && panel.searchField.stringValue == "worker 10000")
        panel.setFailure(DeviceMetricsInventoryError.commandFailed("offline"))
        precondition(panel.visibleRows.count == 1 && panel.countLabel.stringValue == "1 个进程")

        let unavailableCPUPanel = DeviceMetricsInventoryPanel(segment: 1)
        unavailableCPUPanel.update([
            .init(id: "unknown", title: "unknown", subtitle: "", badge: "睡眠", tone: .normal, filter: 0, search: "unknown", cpu: 999, hasCPUUsage: false, pid: 1),
            .init(id: "idle", title: "idle", subtitle: "", badge: "睡眠", tone: .normal, filter: 0, search: "idle", cpu: 0, pid: 2),
            .init(id: "busy", title: "busy", subtitle: "", badge: "运行中", tone: .success, filter: 1, search: "busy", cpu: 7, pid: 3)
        ])
        precondition(unavailableCPUPanel.visibleRows.map(\.id) == ["busy", "idle", "unknown"])
        unavailableCPUPanel.sortControl.sendAction(unavailableCPUPanel.sortControl.action, to: unavailableCPUPanel.sortControl.target)
        precondition(unavailableCPUPanel.visibleRows.map(\.id) == ["idle", "busy", "unknown"])

        let actionPanel = DeviceMetricsInventoryPanel(segment: 1)
        actionPanel.frame = NSRect(x: 0, y: 0, width: 760, height: 500)
        actionPanel.update([
            DeviceMetricsInventoryPanel.Row(
                id: "42", title: "worker", subtitle: "root · PID 42", badge: "运行中",
                tone: .success, filter: 1, search: "worker root 42", pid: 42,
                buttons: [
                    .init(symbol: "pause.fill", title: "暂停进程", action: .process(.pause, 42)),
                    .init(symbol: "xmark.circle", title: "终止进程", action: .process(.terminate, 42)),
                    .init(symbol: "xmark.octagon.fill", title: "强行终止进程（SIGKILL，立即结束）", action: .process(.forceTerminate, 42)),
                    .init(symbol: "gauge", title: "调整优先级", action: .process(.renice(0), 42)),
                ]
            )
        ])
        actionPanel.layoutSubtreeIfNeeded()
        actionPanel.table.layoutSubtreeIfNeeded()
        guard let actionCell = actionPanel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) else {
            preconditionFailure("process action cell was not created")
        }
        actionCell.layoutSubtreeIfNeeded()
        func descendants(of view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants(of:))
        }
        let actionButtons = descendants(of: actionCell).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        precondition(actionButtons.count == 4)
        let rightmostAction = actionButtons.map { $0.convert($0.bounds, to: actionCell).maxX }.max() ?? 0
        precondition(rightmostAction >= actionCell.bounds.maxX - 7)

        let portPanel = DeviceMetricsInventoryPanel(segment: 2)
        portPanel.frame = NSRect(x: 0, y: 0, width: 680, height: 500)
        portPanel.update([
            DeviceMetricsInventoryPanel.Row(
                id: "tcp6:21", title: "[::]:21", subtitle: "未返回进程信息", badge: "TCP6",
                tone: .normal, filter: 1, search: "21 TCP6"
            )
        ])
        portPanel.layoutSubtreeIfNeeded()
        portPanel.table.layoutSubtreeIfNeeded()
        guard let portCell = portPanel.table.view(atColumn: 0, row: 0, makeIfNecessary: true) else {
            preconditionFailure("port cell was not created")
        }
        portCell.layoutSubtreeIfNeeded()
        let portBadge = descendants(of: portCell)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "TCP6" }
        precondition(portBadge != nil)
        let portBadgeRect = portBadge!.convert(portBadge!.bounds, to: portCell)
        // The one-action port column remains reserved even without a known PID.
        // NSTextField extends its alignment rect by 2pt on each horizontal edge.
        precondition(abs(portBadgeRect.maxX - (portCell.bounds.maxX - 35)) <= 1)
        precondition(descendants(of: portCell).compactMap { $0 as? NSButton }.allSatisfy(\.isHidden))
        precondition(abs(portPanel.table.frame.width - portPanel.table.enclosingScrollView!.contentView.bounds.width) < 1)

        for (segment, expected) in [(2, 3), (3, 4), (4, 4)] {
            let view = DeviceMetricsInventoryPanel(segment: segment)
            precondition(view.filterControl.segmentCount == expected)
            view.setFailure(DeviceMetricsInventoryError.authorizationRequired("permission denied"))
            precondition(view.countLabel.stringValue == "尚未加载")
        }
        print("Inventory checks passed: parsers, command validation, narrow layout, filters, ascending/descending sorting, persistent search, retained data on errors, 10000 rows with \(visible.length) visible; \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
    }
}
