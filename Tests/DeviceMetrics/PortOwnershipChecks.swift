import Foundation

// Exercise the production provider with a scripted transport and one local
// shell fixture. No real sudo, remote host, or system process is managed.
struct RemoteCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct PortOwnershipCheckContext {
    let config: Void = ()
    let secret: Void = ()
    let expectedFingerprintSHA256: Void = ()
}

public final class CoreBridgeDeviceMetricsProvider {
    let context = PortOwnershipCheckContext()
    let inventoryWorkerQueue = DispatchQueue(label: "inventory-port-owner-check")
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

private struct ExpectedCall {
    let elevated: Bool
    let password: String?
    let output: String
    let exitCode: Int32

    init(_ output: String, elevated: Bool = false, password: String? = nil, exitCode: Int32 = 0) {
        self.output = output
        self.elevated = elevated
        self.password = password
        self.exitCode = exitCode
    }
}

enum CoreBridge {
    private static var pending: [ExpectedCall] = []
    private(set) static var callCount = 0
    static var shellEnvironment: [String: String]?

    fileprivate static func expect(_ calls: [ExpectedCall]) {
        precondition(pending.isEmpty, "Previous collection did not consume its expected transport calls")
        pending = calls
    }

    static func assertDrained() {
        precondition(pending.isEmpty, "Collection skipped an expected transport call")
    }

    static func runLiveRemoteCommand(config: Void, secret: Void, expectedFingerprintSHA256: Void,
                                     command: String, standardInput: String?) throws -> RemoteCommandResult {
        precondition(!pending.isEmpty, "Unexpected remote call: repeated authorization or unbounded collection")
        let expected = pending.removeFirst()
        let collector = DeviceMetricsInventoryCommands.ports
        let unwrapped = expected.elevated
            ? (expected.password == nil ? "sudo -n " : "sudo -S -p '' ")
                + DeviceMetricsInventoryCommands.privilegedCollector(collector)
            : collector
        precondition(command == DeviceMetricsInventoryCommands.boundedRemoteCommand(unwrapped),
                     "Collector must remain bounded, with the entire sudo shell program quoted as one argument")
        precondition(command.utf8.count + 18 < 32 * 1024,
                     "An SSH exec request including its 18-byte header must stay within the wire budget")
        precondition(standardInput == expected.password.map { $0 + "\n" },
                     "Authorization password was lost or sent to an ordinary read")
        if let password = expected.password {
            precondition(!command.contains(password), "Sudo password escaped into command text")
        }
        callCount += 1
        if let shellEnvironment {
            let process = Process()
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = shellEnvironment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error
            try process.run()
            if let standardInput { try input.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8)) }
            try input.fileHandleForWriting.close()
            // The fixed fixture emits only one socket per source, well below
            // a pipe buffer. No system or arbitrary collector runs here.
            process.waitUntilExit()
            return RemoteCommandResult(stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                                       stderr: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                                       exitCode: process.terminationStatus)
        }
        return RemoteCommandResult(stdout: expected.output, stderr: "", exitCode: expected.exitCode)
    }
}

@main
struct PortOwnershipChecks {
    static func main() throws {
        // The local shell accepts a much longer argument than libssh2's
        // uncompressed single-packet exec request (34,744 bytes). Check the
        // actual serialized UTF-8 command, including the 18-byte exec header,
        // rather than the small unquoted collector or a mock transport input.
        let collector = DeviceMetricsInventoryCommands.ports
        let shellCollector = DeviceMetricsInventoryCommands.privilegedCollector(collector)
        let wireSizes = [("ordinary", collector), ("sudo-n", "sudo -n " + shellCollector),
                         ("sudo-password", "sudo -S -p '' " + shellCollector)].map { name, command in
            let bytes = DeviceMetricsInventoryCommands.boundedRemoteCommand(command).utf8.count + 18
            precondition(bytes < 32 * 1024, "\(name) exec request exceeds the 32 KiB wire budget: \(bytes)")
            return "\(name)=\(bytes)"
        }
        print("Port exec request sizes including 18-byte header: " + wireSizes.joined(separator: ", "))
        func output(_ rows: [String], uid: Int = 1000, collector: String = "__STACIO_SS__") -> String {
            (["__STACIO_PORTS_BEGIN__", "__STACIO_PORT_UID__=\(uid)", collector, "__STACIO_IPV4__"]
                + rows + ["__STACIO_PORTS_END__"]).joined(separator: "\n")
        }
        let known = "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=222,fd=3))"
        let anonymous = "tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:*"
        let knownHTTP = "tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:((\"httpd\",pid=8080,fd=4))"
        let password = "port-fixture-p'\"$ value"
        let denied = ExpectedCall("sudo: a password is required\n", elevated: true, exitCode: 1)

        func collect(_ provider: CoreBridgeDeviceMetricsProvider,
                     _ calls: [ExpectedCall]) -> Result<[ManagedPortInfo], Error> {
            CoreBridge.expect(calls)
            var result: Result<[ManagedPortInfo], Error>?
            provider.listManagedPorts { result = $0 }
            let deadline = Date().addingTimeInterval(3)
            while result == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            }
            guard let result else { preconditionFailure("Port ownership collection did not complete") }
            CoreBridge.assertDrained()
            return result
        }
        func partial(_ result: Result<[ManagedPortInfo], Error>, authorization: Bool,
                     ports: Set<UInt16>, owners: Set<UInt32>) {
            guard case let .failure(error as DeviceMetricsInventoryError) = result,
                  let rows = error.partialPorts else {
                preconditionFailure("Incomplete ownership must preserve the available inventory")
            }
            precondition(error.requiresAuthorization == authorization, "Wrong authorization affordance")
            precondition(Set(rows.map(\.port)) == ports && Set(rows.compactMap(\.pid)) == owners,
                         "Permission failure discarded healthy listeners or their known owners")
            precondition(!error.localizedDescription.contains("__STACIO_"), "Internal markers escaped to users")
        }

        // A complete list, PID-only owner, and authoritative empty response
        // must each require exactly one ordinary read, with no sudo probe.
        let completeProvider = CoreBridgeDeviceMetricsProvider()
        let complete = try collect(completeProvider, [ExpectedCall(output([known, knownHTTP]))]).get()
        precondition(Set(complete.compactMap(\.pid)) == [222, 8080])
        let pidOnly = try collect(completeProvider, [ExpectedCall(output([
            "Proto Recv-Q Send-Q Local Address Foreign Address (state) rhiwat shiwat pid epid",
            "tcp4 0 0 127.0.0.1.9000 *.* LISTEN 131072 131072 34560 0"
        ], collector: "__STACIO_NETSTAT__"))]).get()
        precondition(pidOnly.count == 1 && pidOnly[0].pid == 34560 && pidOnly[0].processName.isEmpty,
                     "A known PID without a process name should not trigger authorization")
        let empty = try collect(completeProvider, [ExpectedCall(output([]))]).get()
        precondition(empty.isEmpty)

        // A normal-user read can succeed while the owner field remains hidden.
        // Ask for authorization once and keep refreshing the visible sockets.
        let provider = CoreBridgeDeviceMetricsProvider()
        partial(collect(provider, [ExpectedCall(output([known, anonymous])), denied]),
                authorization: true, ports: [22, 80], owners: [222])
        partial(collect(provider, [ExpectedCall(output([anonymous]))]),
                authorization: true, ports: [80], owners: [])
        let recoveredOrdinary = try collect(provider, [ExpectedCall(output([known]))]).get()
        precondition(recoveredOrdinary.count == 1 && recoveredOrdinary[0].pid == 222,
                     "A cached denial must not mask a later complete ordinary result")

        // An explicitly supplied password invalidates the cached denial. It is
        // forwarded only through stdin; later polling directly reuses the
        // successful elevated identity instead of doubling every refresh.
        provider.setInventorySudoPassword(password)
        let authorized = try collect(provider, [ExpectedCall(output([known, anonymous])),
            ExpectedCall(output([known, knownHTTP], uid: 0), elevated: true, password: password)]).get()
        precondition(Set(authorized.compactMap(\.pid)) == [222, 8080])
        let fastRefresh = try collect(provider, [
            ExpectedCall(output([knownHTTP], uid: 0), elevated: true, password: password)
        ]).get()
        precondition(fastRefresh.count == 1 && fastRefresh[0].pid == 8080)

        // If elevated access expires, retain ordinary rows and suspend further
        // sudo attempts until an explicit retry instead of hiding all sockets.
        partial(collect(provider, [ExpectedCall("sudo: 1 incorrect password attempt\n", elevated: true,
                                               password: password, exitCode: 1),
                                   ExpectedCall(output([known, anonymous]))]),
                authorization: true, ports: [22, 80], owners: [222])
        precondition(provider.inventorySudoPassword == nil, "Rejected password was retained")
        partial(collect(provider, [ExpectedCall(output([anonymous]))]),
                authorization: true, ports: [80], owners: [])
        provider.retryInventoryAuthorization()
        let retried = try collect(provider, [ExpectedCall(output([anonymous])),
            ExpectedCall(output([knownHTTP], uid: 0), elevated: true)]).get()
        precondition(retried.first?.pid == 8080, "Explicit authorization retry did not clear the cached failure")

        // A non-authentication admin failure also falls back to the current
        // ordinary inventory without promising that a password will fix it.
        partial(collect(provider, [ExpectedCall("collector unavailable", elevated: true, exitCode: 127),
                                   ExpectedCall(output([known, anonymous]))]),
                authorization: false, ports: [22, 80], owners: [222])
        partial(collect(provider, [ExpectedCall(output([anonymous]))]),
                authorization: false, ports: [80], owners: [])

        // Root already has the available privilege: do not execute sudo or
        // present a password button when the platform itself omits ownership.
        let rootProvider = CoreBridgeDeviceMetricsProvider()
        partial(collect(rootProvider, [ExpectedCall(output([known, anonymous], uid: 0))]),
                authorization: false, ports: [22, 80], owners: [222])
        partial(collect(rootProvider, [ExpectedCall(output([anonymous], uid: 0))]),
                authorization: false, ports: [80], owners: [])

        // Even a successful sudo read may omit kernel/container-owned sockets.
        // Keep its working identity so later refreshes retain the owners that
        // are only available to root, despite the remaining partial warning.
        let omittedProvider = CoreBridgeDeviceMetricsProvider()
        partial(collect(omittedProvider, [ExpectedCall(output([anonymous])),
            ExpectedCall(output([known, anonymous], uid: 0), elevated: true)]),
                authorization: false, ports: [22, 80], owners: [222])
        partial(collect(omittedProvider, [ExpectedCall(output([known, anonymous], uid: 0), elevated: true)]),
                authorization: false, ports: [22, 80], owners: [222])

        // An authorization reset and a newer request each protect their state
        // from an older completion arriving after the user has already retried.
        let state = ManagedPortOwnershipState()
        let old = state.begin()
        state.reset()
        state.complete(old.generation, preferElevation: true, failure: .authorizationRequired("stale"))
        let afterReset = state.begin()
        precondition(!afterReset.preferElevation && afterReset.failure == nil)
        let newest = state.begin()
        state.complete(newest.generation, preferElevation: true, failure: nil)
        state.complete(afterReset.generation, preferElevation: false, failure: .commandFailed("stale"))
        let final = state.begin()
        precondition(final.preferElevation && final.failure == nil)

        // Run the actual multi-layer shell quoting and password stdin route,
        // with ss/id/sudo confined to fixtures ahead of every system path.
        // A shell program incorrectly passed to sudo as an executable (or
        // split into multiple arguments) fails the mock's strict argv check.
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-port-ownership-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        func fixture(_ name: String, _ script: String) throws {
            let file = fixtureDirectory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + script).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try fixture("id", "if [ \"${STACIO_TEST_ELEVATED:-}\" = 1 ]; then printf '0\\n'; else printf '1000\\n'; fi")
        try fixture("ss", """
        case " $* " in
          *' -6 '*) exit 0 ;;
          *' -4 '*)
            if [ "${STACIO_TEST_ELEVATED:-}" = 1 ]; then
              printf '%s\\n' \(DeviceMetricsInventoryCommands.quote(knownHTTP))
            else
              printf '%s\\n' \(DeviceMetricsInventoryCommands.quote(anonymous))
            fi ;;
          *) exit 2 ;;
        esac
        """)
        try fixture("sudo", """
        if [ "$1" = -n ]; then printf 'sudo: a password is required\\n' >&2; exit 1; fi
        [ "$1" = -S ] && [ "$2" = -p ] && [ "$3" = '' ] || exit 92
        shift 3
        [ "$#" = 6 ] && [ "$1" = sh ] && [ "$2" = -c ] && [ "$4" = stacio-supervisor ] || exit 93
        IFS= read -r supplied || exit 94
        [ "$supplied" = \(DeviceMetricsInventoryCommands.quote(password)) ] || exit 95
        exec /usr/bin/env -i PATH=\(DeviceMetricsInventoryCommands.quote(fixtureDirectory.path + ":/usr/bin:/bin:/usr/sbin:/sbin")) TMPDIR=\(DeviceMetricsInventoryCommands.quote(fixtureDirectory.path)) STACIO_TEST_ELEVATED=1 "$@"
        """)
        var fixtureEnvironment = ProcessInfo.processInfo.environment
        fixtureEnvironment["PATH"] = fixtureDirectory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        fixtureEnvironment["TMPDIR"] = fixtureDirectory.path
        CoreBridge.shellEnvironment = fixtureEnvironment
        defer { CoreBridge.shellEnvironment = nil }
        let shellProvider = CoreBridgeDeviceMetricsProvider()
        partial(collect(shellProvider, [ExpectedCall(""), denied]), authorization: true, ports: [80], owners: [])
        shellProvider.setInventorySudoPassword(password)
        let shellRows = try collect(shellProvider, [ExpectedCall(""), ExpectedCall("", elevated: true, password: password)]).get()
        precondition(shellRows.count == 1 && shellRows[0].pid == 8080 && shellRows[0].processName == "httpd",
                     "Actual bounded shell/sudo quoting failed to enrich the socket owner")
        // Verify the optional timeout branch preserves the same executable
        // arguments and password stdin. The full command suite separately
        // exercises real 25-second watchdogs with/without a process group.
        let timeoutMarker = fixtureDirectory.appendingPathComponent("timeout-used")
        try fixture("timeout", """
        [ "$1" = 25s ] || exit 96
        shift
        printf 'called' > \(DeviceMetricsInventoryCommands.quote(timeoutMarker.path))
        exec "$@"
        """)
        let timeoutRows = try collect(shellProvider, [ExpectedCall("", elevated: true, password: password)]).get()
        precondition(timeoutRows.first?.pid == 8080 && FileManager.default.fileExists(atPath: timeoutMarker.path),
                     "The timeout branch changed the command arguments, stdin, or result")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path)
        precondition(Set(remaining) == ["ss", "id", "sudo", "timeout", "timeout-used"], "Port or watchdog scratch directory leaked")

        print("Port ownership checks passed: \(CoreBridge.callCount) bounded transport calls; ordinary/PID-only/empty rows, mixed ownership, cached denial, explicit authorization and retry, stdin-only password, fast elevated refresh, failed-admin fallback, root/platform limits, stale completion protection")
    }
}
