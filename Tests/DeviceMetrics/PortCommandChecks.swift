import Foundation
import Darwin

// Compile the production provider and parser against local command fixtures.
// Real netstat/lsof checks inspect this test's temporary loopback sockets.
struct RemoteCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct PortCheckContext {
    let config: Void = ()
    let secret: Void = ()
    let expectedFingerprintSHA256: Void = ()
}

public final class CoreBridgeDeviceMetricsProvider {
    let context = PortCheckContext()
    let inventoryWorkerQueue = DispatchQueue(label: "inventory-port-check")
    let inventoryRequestSlots = DispatchSemaphore(value: 2)
    let inventoryStateLock = NSLock()
    let inventoryProcessCPUSampler = ManagedProcessCPUSampler()
    let inventoryPortOwnershipState = ManagedPortOwnershipState()
    var inventorySudoPassword: String?
    var inventorySudoAuthorizationGeneration: UInt64 = 0
    var inventoryElevationRequired = Set<String>()
    var inventoryContainerReadIdentity: [String: Bool] = [:]
    var inventoryContainerAuthorizationFailures: [String: DeviceMetricsInventoryError] = [:]
    var inventoryContainerAuthorizationGeneration: UInt64 = 0
}

enum CoreBridge {
    static var environment = ProcessInfo.processInfo.environment
    static var lastOutput = ""

    static func runLiveRemoteCommand(config: Void, secret: Void, expectedFingerprintSHA256: Void,
                                     command: String, standardInput: String?) throws -> RemoteCommandResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-port-capture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let result = RemoteCommandResult(stdout: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                                         stderr: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self),
                                         exitCode: process.terminationStatus)
        if result.stdout.contains("__STACIO_PORTS_BEGIN__") { lastOutput = result.stdout }
        return result
    }
}

@main
struct PortCommandChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-port-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        CoreBridge.environment["PATH"] = directory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        CoreBridge.environment["TMPDIR"] = directory.path

        func fixture(_ name: String, _ body: String) throws {
            let url = directory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        func collect(waitSeconds: TimeInterval = 8) -> Result<[ManagedPortInfo], Error> {
            let provider = CoreBridgeDeviceMetricsProvider()
            var result: Result<[ManagedPortInfo], Error>?
            provider.listManagedPorts { result = $0 }
            let deadline = Date().addingTimeInterval(waitSeconds)
            while result == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard let result else { preconditionFailure("Local port collection did not complete") }
            // This suite verifies collector formats. Ownership authorization
            // has its own provider suite; retain its available rows here.
            if case let .failure(error as DeviceMetricsInventoryError) = result,
               let rows = error.partialPorts { return .success(rows) }
            return result
        }
        func expectFailure(_ result: Result<[ManagedPortInfo], Error>) {
            guard case .failure(DeviceMetricsInventoryError.commandFailed(let message)) = result else {
                preconditionFailure("Collection failure became an empty or partial success: \(result)")
            }
            precondition(message.contains("operation not permitted"), "Collector diagnostic was not preserved")
            precondition(!message.contains("9999"), "Partial stdout from a failed collector escaped")
            precondition(!message.contains("__STACIO_"), "Internal markers escaped into the user-facing error")
            precondition(!message.contains("4242"), "A partial family inventory escaped into the error")
        }

        let failed = "printf 'tcp LISTEN 0 128 *:9999 *:*\\n'; printf 'operation not permitted\\n' >&2; exit 2"
        // Native netstat may include inaccessible system sockets. Never let
        // ownership enrichment invoke the machine's real sudo in this suite.
        try fixture("sudo", "printf 'sudo: a password is required\\n' >&2; exit 1")
        for name in ["ss", "netstat", "lsof"] { try fixture(name, failed) }
        expectFailure(collect())

        // A successful collector with no sockets is an authoritative empty list.
        try fixture("ss", "exit 0")
        let emptySS = try collect().get()
        precondition(emptySS.isEmpty)
        try fixture("ss", failed)
        try fixture("lsof", "exit 1")
        let emptyLsof = try collect().get()
        precondition(emptyLsof.isEmpty, "lsof's silent no-match exit must remain a valid empty result")
        // A fallback can be the only successful source. COMMAND/USER equal to
        // a protocol must not turn its valid sockets into an empty success.
        try fixture("lsof", """
        case " $* " in
          *' -iTCP '*) printf '%s\\n' \
            'tcp 31 root 3u IPv4 0x123 0t0 TCP 127.0.0.1:64132 (LISTEN)' \
            'server 32 tcp 4u IPv6 12345 0t0 TCP *:64133 (LISTEN)' \
            'udp 35 tcp 5u IPv4 12346 0t0 TCP 127.0.0.1:64134->127.0.0.1:64135 (ESTABLISHED)' ;;
          *' -iUDP '*) printf '%s\\n' \
            'udp 33 root 3u IPv4 0x456 0t0 UDP 127.0.0.1:64136' \
            'server 34 udp 4u IPv6 12347 0t0 UDP *:64137' \
            'tcp 36 udp 5u IPv6 12348 0t0 UDP [::1]:64138->[::1]:64139' ;;
          *) exit 2 ;;
        esac
        """)
        let protocolNamedOwners = try collect().get()
        precondition(protocolNamedOwners.count == 4 && Set(protocolNamedOwners.compactMap(\.pid)) == [31, 32, 33, 34],
                     "lsof protocol names in COMMAND/USER lost or invented a listening socket")
        precondition(Set(protocolNamedOwners.map(\.protocolName)) == ["TCP", "TCP6", "UDP", "UDP6"])
        precondition(protocolNamedOwners.first { $0.pid == 31 }?.processName == "tcp"
                     && protocolNamedOwners.first { $0.pid == 33 }?.processName == "udp")
        try fixture("lsof", failed)

        let ipv4 = "printf '%s\\n' 'tcp LISTEN 0 128 *:4242 *:* users:((\"v4\",pid=111,fd=4))'"
        let ipv6 = "printf '%s\\n' 'tcp LISTEN 0 128 *:4242 *:* users:((\"v6\",pid=222,fd=4))'"
        try fixture("ss", """
        case " $* " in
          *' -4 '*) \(ipv4);;
          *' -6 '*) \(ipv6);;
          *) exit 2;;
        esac
        """)
        let families = try collect().get()
        precondition(Set(families.map(\.protocolName)) == ["TCP", "TCP6"] && families.count == 2,
                     "ss wildcard sockets lost their explicit address family")

        // A complete source must not depend on optional collectors: lsof may
        // block while inspecting file descriptors or an unavailable filesystem.
        let slowCollectorMarker = directory.appendingPathComponent("slow-collector-called")
        let slowCollector = "touch \(DeviceMetricsInventoryCommands.quote(slowCollectorMarker.path)); sleep 60"
        try fixture("netstat", slowCollector)
        try fixture("lsof", slowCollector)
        let completeSSStarted = Date()
        let completeSS = try collect().get()
        precondition(Date().timeIntervalSince(completeSSStarted) < 5,
                     "Complete ss results waited for an optional collector")
        precondition(Set(completeSS.map(\.protocolName)) == ["TCP", "TCP6"] && Set(completeSS.compactMap(\.pid)) == [111, 222],
                     "Returning the complete ss source lost its family or process owners")
        precondition(!FileManager.default.fileExists(atPath: slowCollectorMarker.path),
                     "An optional collector ran after a complete ss result")
        try fixture("ss", "exit 0")
        let completeEmptySS = try collect().get()
        precondition(completeEmptySS.isEmpty && !FileManager.default.fileExists(atPath: slowCollectorMarker.path),
                     "An authoritative empty ss result must also skip optional collectors")
        try fixture("netstat", failed)
        try fixture("lsof", failed)

        // Older implementations may support -f inet6 instead of -6.
        try fixture("ss", """
        case " $* " in
          *' -4 '*) \(ipv4);;
          *' -f inet6 '*) \(ipv6);;
          *) \(failed);;
        esac
        """)
        let alternateFamily = try collect().get()
        precondition(alternateFamily.count == 2 && alternateFamily.contains { $0.protocolName == "TCP6" })
        precondition(alternateFamily.allSatisfy { $0.port != 9999 })

        // One working family alone must not be presented as a complete inventory.
        try fixture("ss", """
        case " $* " in *' -4 '*) \(ipv4);; *) \(failed);; esac
        """)
        expectFailure(collect())
        try fixture("netstat", "printf '%s\\n' 'tcp6 0 0 :::4242 :::* LISTEN 222/v6'")
        try fixture("lsof", slowCollector)
        let completeNetstatStarted = Date()
        let supplemented = try collect().get()
        precondition(Date().timeIntervalSince(completeNetstatStarted) < 5 && !FileManager.default.fileExists(atPath: slowCollectorMarker.path),
                     "Complete netstat results waited for optional lsof")
        precondition(supplemented.contains { $0.protocolName == "TCP6" && $0.pid == 222 })
        precondition(supplemented.contains { $0.protocolName == "TCP" && $0.pid == 111 })

        // Darwin's verbose owner field is process:pid on current systems, and
        // numeric pid/epid on older releases. The latter is documented in
        // Apple's network_cmds-543/netstat.tproj/inet.c. Do not infer an owner
        // from an endpoint's colon or retain a layout across collector sections.
        let darwinOwners = DeviceMetricsInventoryParser.ports("""
        __STACIO_NETSTAT__
        Proto Recv-Q Send-Q Local Address Foreign Address (state) rxbytes txbytes rhiwat shiwat process:pid state options gencnt flags flags1 usecnt rtncnt fltrs
        tcp6 0 0 ::1.14443 *.* LISTEN 0 0 131072 131072 Worker (TCP):23456 00000 00000002 0000000000000001 00000000 00000800 1 0 000000
        udp4 0 0 127.0.0.1.14553 *.* 0 0 8192 8192 dns:worker:23457 00000 00000002 0000000000000001 00000000 00000800 1 0 000000
        tcp4 0 0 127.0.0.1.14554 *.* LISTEN 0 0 131072 131072 unknown 00000 00000002 0000000000000001 00000000 00000800 1 0 000000
        __STACIO_NETSTAT__
        Proto Recv-Q Send-Q Local Address Foreign Address (state) rhiwat shiwat pid epid
        tcp4 0 0 *.14666 *.* LISTEN 131072 131072 34560 0
        udp6 0 0 *.14667 *.* 8192 8192 34561 0
        __STACIO_SS__
        __STACIO_IPV6__
        tcp LISTEN 0 128 [2001:db8::1234]:14888 [::]:*
        __STACIO_NETSTAT__
        Proto Recv-Q Send-Q Local Address Foreign Address State PID/Program name
        tcp6 0 0 :::14999 :::* LISTEN 45678/linux-server
        tcp6 0 0 :::15000 :::* LISTEN -
        """)
        precondition(darwinOwners.count == 8, "An owner layout change dropped a valid listening socket")
        precondition(darwinOwners.first { $0.port == 14443 }?.pid == 23456 && darwinOwners.first { $0.port == 14443 }?.processName == "Worker (TCP)")
        precondition(darwinOwners.first { $0.port == 14553 }?.pid == 23457 && darwinOwners.first { $0.port == 14553 }?.processName == "dns:worker")
        precondition(darwinOwners.first { $0.port == 14666 }?.pid == 34560 && darwinOwners.first { $0.port == 14667 }?.pid == 34561,
                     "Legacy Darwin TCP/UDP pid columns were misaligned")
        precondition(darwinOwners.first { $0.port == 14999 }?.pid == 45678 && darwinOwners.first { $0.port == 14999 }?.processName == "linux-server")
        precondition(darwinOwners.filter { [14554, 14888, 15000].contains($0.port) }.allSatisfy { $0.pid == nil && $0.processName.isEmpty },
                     "An endpoint or malformed owner became a process identity")

        // Exercise the actual platform lsof binary against a known unconnected
        // UDP socket, rather than teaching a fixture to accept its arguments.
        let socketFD = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        precondition(socketFD >= 0)
        defer { Darwin.close(socketFD) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0)
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &addressLength)
            }
        }
        precondition(named == 0)
        let port = UInt16(bigEndian: address.sin_port)
        try fixture("ss", failed)
        try fixture("netstat", failed)
        try fixture("lsof", "exec /usr/sbin/lsof -a -p \(getpid()) \"$@\"")
        let localUDP = try collect().get()
        precondition(localUDP.contains { $0.protocolName == "UDP" && $0.port == port && $0.pid == UInt32(getpid()) },
                     "Production lsof fallback omitted a real local UDP socket")

        // Exercise the normal macOS netstat path, not just a forced lsof
        // fallback. Both sockets must retain the owner while lsof stays skipped.
        let tcpFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        precondition(tcpFD >= 0)
        defer { Darwin.close(tcpFD) }
        address.sin_port = 0
        precondition(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(tcpFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0)
        precondition(Darwin.listen(tcpFD, 1) == 0)
        precondition(withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(tcpFD, $0, &addressLength)
            }
        } == 0)
        let tcpPort = UInt16(bigEndian: address.sin_port)
        try fixture("netstat", "exec /usr/sbin/netstat \"$@\"")
        try fixture("lsof", slowCollector)
        let nativeNetstatStarted = Date()
        let nativePorts = try collect().get()
        precondition(Date().timeIntervalSince(nativeNetstatStarted) < 5 && !FileManager.default.fileExists(atPath: slowCollectorMarker.path))
        let nativeOwners = nativePorts.filter {
            ($0.port == port && $0.protocolName == "UDP") || ($0.port == tcpPort && $0.protocolName == "TCP")
        }
        precondition(nativeOwners.count == 2 && nativeOwners.allSatisfy { $0.pid == UInt32(getpid()) },
                     "Normal Darwin netstat collection lost the real TCP/UDP process owner")
        if CoreBridge.lastOutput.contains("process:pid") {
            precondition(nativeOwners.allSatisfy { $0.processName == ProcessInfo.processInfo.processName },
                         "Darwin process:pid did not preserve the owning process name")
        }

        // The collector's own trap cannot run after SIGKILL. Its scratch files
        // must still be removed by the surviving outer watchdog wrapper.
        try fixture("ss", "sleep 60")
        let began = Date()
        let timedOut = collect(waitSeconds: 33)
        precondition(Date().timeIntervalSince(began) >= 24 && Date().timeIntervalSince(began) < 33)
        guard case .failure = timedOut else { preconditionFailure("A timed-out collector succeeded") }

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(remaining.allSatisfy { !$0.hasPrefix("stacio-ports.") && !$0.hasPrefix("stacio-command.") },
                     "Collector temporary files were not removed")
        print("Port command checks passed: errors, empty results, IPv4/IPv6, fast complete sources, family fallback, partial output rejection, Darwin owners, real netstat TCP/UDP, real lsof UDP, timeout cleanup")
    }
}
