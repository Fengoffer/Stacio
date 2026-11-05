import Foundation
import Darwin

// Compile the production inventory provider against a local transport. All
// management commands resolve to fixtures; these checks never contact a host.
struct RemoteCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct CommandCheckContext {
    let config: Void = ()
    let secret: Void = ()
    let expectedFingerprintSHA256: Void = ()
}

public final class CoreBridgeDeviceMetricsProvider {
    let context = CommandCheckContext()
    let inventoryWorkerQueue = DispatchQueue(label: "inventory-command-check")
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
    static var calls: [(command: String, input: String?)] = []
    static var didReturn: ((RemoteCommandResult) -> Void)?
    static var processCounterFixturePath: String?

    static func runLiveRemoteCommand(config: Void, secret: Void, expectedFingerprintSHA256: Void,
                                     command: String, standardInput: String?) throws -> RemoteCommandResult {
        calls.append((command, standardInput))
        // macOS has no procfs. Redirect only the production process collector's
        // paths to a local proc-shaped fixture while executing its real awk,
        // format negotiation, watchdog wrapper, parser, and interval sampler.
        let localCommand: String
        if let fixturePath = processCounterFixturePath,
           command == DeviceMetricsInventoryCommands.boundedRemoteCommand(DeviceMetricsInventoryCommands.processes) {
            localCommand = DeviceMetricsInventoryCommands.boundedRemoteCommand(
                DeviceMetricsInventoryCommands.processes.replacingOccurrences(of: "/proc/", with: fixturePath + "/"))
        } else {
            localCommand = command
        }
        let result = try runShell(localCommand, input: standardInput, environment: environment)
        didReturn?(result)
        return result
    }
}

private func runShell(_ command: String, input: String? = nil, environment: [String: String]) throws -> RemoteCommandResult {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-command-capture-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let stdoutURL = temporary.appendingPathComponent("stdout")
    let stderrURL = temporary.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer { try? stdout.close(); try? stderr.close() }
    let process = Process()
    let stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = environment
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    return RemoteCommandResult(
        stdout: String(decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
        stderr: String(decoding: try Data(contentsOf: stderrURL), as: UTF8.self),
        exitCode: process.terminationStatus)
}

@main
struct CommandChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stacio-command-check-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ProcessInfo.processInfo.environment
        // Exclude optional host-installed tools so the first pass exercises
        // the portable fallback without setsid or GNU timeout.
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TMPDIR"] = directory.path
        let quote = DeviceMetricsInventoryCommands.quote

        func run(_ command: String, input: String? = nil) throws -> RemoteCommandResult {
            try runShell(DeviceMetricsInventoryCommands.boundedRemoteCommand(command), input: input, environment: environment)
        }

        for (name, collector) in [("Process", DeviceMetricsInventoryCommands.processes), ("Port", DeviceMetricsInventoryCommands.ports)] {
            let commands = [collector, "sudo -n " + DeviceMetricsInventoryCommands.privilegedCollector(collector),
                            "sudo -S -p '' " + DeviceMetricsInventoryCommands.privilegedCollector(collector)]
            let sizes = commands.map { DeviceMetricsInventoryCommands.boundedRemoteCommand($0).utf8.count + 18 }
            precondition(sizes.allSatisfy { $0 < 32 * 1024 }, "\(name) collector exceeded SSH wire budget")
            print("\(name) exec request sizes including 18-byte header: ordinary=\(sizes[0]), sudo-n=\(sizes[1]), sudo-password=\(sizes[2])")
        }

        let start = Date()
        let ordinary = try run("printf '{\"ok\":true}'")
        precondition(ordinary.exitCode == 0 && ordinary.stdout == "{\"ok\":true}" && ordinary.stderr.isEmpty)
        precondition(Date().timeIntervalSince(start) < 5, "Successful commands must not wait for the watchdog")
        let stdin = try run("IFS= read -r value; [ \"$value\" = \"test input\" ] && printf stdin-ok", input: "test input\n")
        precondition(stdin.exitCode == 0 && stdin.stdout == "stdin-ok", "Background runner lost stdin")
        let failure = try run("printf partial; printf 'permission denied' >&2; exit 9")
        precondition(failure.exitCode == 9 && failure.stdout == "partialpermission denied")

        func fixture(_ name: String, _ body: String) throws {
            let url = directory.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try fixture("systemctl", """
        if [ "${STACIO_TEST_ELEVATED:-}" != 1 ]; then printf 'permission denied' >&2; exit 1; fi
        printf 'managed-ok'
        """)
        let sudoFixture = """
        if [ "$1" = -n ]; then printf 'sudo: a password is required' >&2; exit 1; fi
        [ "$1" = -S ] && [ "$2" = -p ] || exit 2
        shift 3
        IFS= read -r password || { printf 'sudo: no password was provided' >&2; exit 1; }
        if [ "$password" != 'test-password' ]; then printf 'Sorry, try again.\nsudo: 1 incorrect password attempt\n' >&2; exit 1; fi
        export STACIO_TEST_ELEVATED=1
        exec "$@"
        """
        try fixture("sudo", sudoFixture)
        environment["PATH"] = directory.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        CoreBridge.environment = environment
        let provider = CoreBridgeDeviceMetricsProvider()

        func serviceAction() throws -> Result<Void, Error> {
            var completion: Result<Void, Error>?
            provider.performServiceAction(.stop, name: "stacio-command-check.service", scope: "system") { completion = $0 }
            let deadline = Date().addingTimeInterval(8)
            while completion == nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard let completion else { preconditionFailure("Local management action failed to complete") }
            return completion
        }

        let authorization = try serviceAction()
        guard case .failure(DeviceMetricsInventoryError.authorizationRequired(let message)) = authorization else {
            preconditionFailure("Merged permission diagnostic did not trigger sudo authorization: \(authorization)")
        }
        precondition(message.contains("a password is required") && CoreBridge.calls.count == 2)
        provider.setInventorySudoPassword("test-password")
        try serviceAction().get()
        precondition(CoreBridge.calls.last?.input == "test-password\n")
        precondition(!CoreBridge.calls.last!.command.contains("test-password"), "Password leaked into command text")
        provider.setInventorySudoPassword("wrong-password")
        guard case .failure(DeviceMetricsInventoryError.authorizationRequired(let incorrect)) = try serviceAction() else {
            preconditionFailure("Incorrect password did not remain retryable")
        }
        precondition(incorrect.contains("incorrect password") && provider.inventorySudoPassword == nil)

        try fixture("systemctl", "printf 'unit disappeared' >&2; exit 5")
        provider.inventoryElevationRequired.removeAll()
        guard case .failure(DeviceMetricsInventoryError.commandFailed(let diagnostic)) = try serviceAction() else {
            preconditionFailure("Non-permission failure had the wrong error type")
        }
        precondition(diagnostic == "unit disappeared", "Failure diagnostic was lost from merged stdout")

        try fixture("docker", #"printf '%s\n' '{"ID":"aaaa","Names":"docker-app","State":"running","Image":"app"}'"#)
        try fixture("podman", """
        if [ "${STACIO_TEST_ELEVATED:-}" != 1 ]; then printf 'permission denied' >&2; exit 1; fi
        printf '%s\\n' '{"ID":"bbbb","Names":["podman-app"],"State":"running","Image":"app"}'
        """)
        func containerList() -> Result<[ManagedContainerInfo], Error> {
            var result: Result<[ManagedContainerInfo], Error>?
            provider.listManagedContainers { result = $0 }
            let deadline = Date().addingTimeInterval(8)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let result else { preconditionFailure("Container list failed to complete") }
            return result
        }

        // podman-docker emits this compatibility notice on stderr even when
        // the Docker-compatible command succeeds. The bounded transport merges
        // stderr into stdout, so the exact notice may be ignored while every
        // other diagnostic must still fail strict JSON validation.
        let podmanDockerWarning = "Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet msg."
        try fixture("docker", "printf '%s\\n' \(quote(podmanDockerWarning)) >&2; exit 0")
        try fixture("podman", "exit 0")
        provider.retryInventoryAuthorization()
        let warningEmpty = try containerList().get()
        precondition(warningEmpty.isEmpty, "podman-docker warning broke a successful empty inventory")
        try fixture("docker", "printf '%s\\n' \(quote(podmanDockerWarning)) >&2; printf '%s\\n' '{\"ID\":\"aaaa\",\"Names\":\"docker-app\",\"State\":\"running\",\"Image\":\"app\"}'")
        let warningRows = try containerList().get()
        precondition(warningRows.map(\.name) == ["docker-app"], "podman-docker warning hid valid JSON rows")
        try fixture("docker", "printf '%s\\n' \(quote(podmanDockerWarning)) >&2; printf 'daemon unavailable' >&2; exit 3")
        guard case let .failure(warningError as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("A real daemon error after the compatibility warning was swallowed")
        }
        precondition(!warningError.requiresAuthorization && warningError.partialContainers?.isEmpty == true)
        precondition(warningError.localizedDescription.contains("daemon unavailable"), "The real daemon diagnostic was lost")
        for unknownDiagnostic in [podmanDockerWarning + "\nunknown daemon warning", podmanDockerWarning + " with unexpected suffix"] {
            try fixture("docker", "printf '%s\\n' \(quote(unknownDiagnostic)) >&2; exit 0")
            guard case let .failure(unknownError as DeviceMetricsInventoryError) = containerList() else {
                preconditionFailure("Unknown text was swallowed along with the podman-docker notice")
            }
            precondition(!unknownError.requiresAuthorization && unknownError.partialContainers?.isEmpty == true)
            precondition(unknownError.localizedDescription.contains(DeviceMetricsInventoryError.invalidResponse.localizedDescription))
        }
        try fixture("docker", "exit 0")
        try fixture("podman", "printf '%s\\n' \(quote(podmanDockerWarning)) >&2; exit 0")
        guard case let .failure(podmanNoticeError as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("Docker compatibility notice was incorrectly filtered for a native Podman command")
        }
        precondition(!podmanNoticeError.requiresAuthorization && podmanNoticeError.partialContainers?.isEmpty == true)
        precondition(podmanNoticeError.localizedDescription.contains(DeviceMetricsInventoryError.invalidResponse.localizedDescription))

        // podman-docker is an alias, not a second container store. Resolve it
        // without deduplicating unrelated Docker/Podman IDs.
        provider.inventoryContainerReadIdentity.removeAll()
        provider.retryInventoryAuthorization()
        try fixture("docker", "if [ \"$1\" = --version ]; then printf 'podman version 5.4.2\\n'; else printf 'unexpected docker query' >&2; exit 8; fi")
        try fixture("podman", "printf '%s\\n' '{\"ID\":\"aaaa\",\"Names\":\"podman-only\",\"State\":\"running\"}'")
        let beforeAlias = CoreBridge.calls.count
        let aliased = try containerList().get()
        precondition(aliased.count == 1 && aliased[0].engine == "podman" && aliased[0].name == "podman-only")
        precondition(CoreBridge.calls.count == beforeAlias + 2, "Alias caused a second inventory request")
        try fixture("docker", "if [ \"$1\" = --version ]; then printf 'Docker version 28.0\\n'; else printf '%s\\n' '{\"ID\":\"aaaa\",\"Names\":\"docker-independent\",\"State\":\"running\"}'; fi")
        let independent = try containerList().get()
        precondition(independent.count == 2 && Set(independent.map(\.engine)) == ["docker", "podman"], "Unrelated backends sharing an ID were merged")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("docker"))
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("docker"), withDestinationURL: directory.appendingPathComponent("podman"))
        let linked = try containerList().get()
        precondition(linked.count == 1 && linked[0].engine == "podman", "Symlinked podman-docker was queried twice")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("docker"))

        // Restore the normal fixtures and clear identities learned by the
        // compatibility-only probes before exercising sudo/partial behavior.
        provider.inventoryContainerReadIdentity.removeAll()
        provider.retryInventoryAuthorization()
        try fixture("docker", #"printf '%s\n' '{"ID":"aaaa","Names":"docker-app","State":"running","Image":"app"}'"#)
        try fixture("podman", """
        if [ "${STACIO_TEST_ELEVATED:-}" != 1 ]; then printf 'permission denied' >&2; exit 1; fi
        printf '%s\\n' '{"ID":"bbbb","Names":["podman-app"],"State":"running","Image":"app"}'
        """)
        guard case let .failure(partial as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("A partial container list must expose its failed engine")
        }
        precondition(partial.partialContainers?.map(\.name) == ["docker-app"] && partial.requiresAuthorization)
        precondition(partial.localizedDescription.contains("Podman"))

        // A denied Podman read is cached independently. Healthy Docker keeps
        // polling, including an empty result that can later gain containers.
        try fixture("docker", "exit 0")
        let beforeHealthyRefresh = CoreBridge.calls.count
        guard case let .failure(emptyPartial as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("An empty healthy engine must remain a partial inventory")
        }
        precondition(emptyPartial.partialContainers?.isEmpty == true && emptyPartial.requiresAuthorization)
        precondition(CoreBridge.calls.count == beforeHealthyRefresh + 2, "Automatic polling retried a denied engine")
        try fixture("docker", #"printf '%s\n' '{"ID":"aaaa","Names":"new-docker-app","State":"running","Image":"app"}'"#)
        guard case let .failure(changedPartial as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("Healthy Docker data stopped updating")
        }
        precondition(changedPartial.partialContainers?.map(\.name) == ["new-docker-app"])
        let beforeExplicitRetry = CoreBridge.calls.count
        provider.retryInventoryAuthorization()
        guard case .failure = containerList() else { preconditionFailure("Unchanged denied engine unexpectedly succeeded") }
        precondition(CoreBridge.calls.count == beforeExplicitRetry + 4, "Explicit refresh failed to retry the denied engine")

        provider.setInventorySudoPassword("test-password")
        let recovered = try containerList().get()
        precondition(Set(recovered.map(\.engine)) == ["docker", "podman"])
        precondition(provider.inventoryContainerReadIdentity == ["docker": false, "podman": true])

        func containerAction() -> Result<Void, Error> {
            var result: Result<Void, Error>?
            provider.performContainerAction(.stop, id: "bbbb", engine: "podman") { result = $0 }
            let deadline = Date().addingTimeInterval(8)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let result else { preconditionFailure("Container action failed to complete") }
            return result
        }
        try containerAction().get()
        precondition(CoreBridge.calls.last?.input == "test-password\n", "Root-owned container action lost its read identity")
        for businessError in [
            "Error response from daemon: OCI runtime create failed: permission denied",
            "container runtime: operation not permitted",
            "container is busy; try again",
            "application log: sudo: a password is required"
        ] {
            try fixture("podman", "printf '%s' \(quote(businessError)) >&2; exit 1")
            guard case .failure(DeviceMetricsInventoryError.commandFailed(let message)) = containerAction() else {
                preconditionFailure("Authenticated container failure incorrectly requested another sudo password")
            }
            precondition(message == businessError && provider.inventorySudoPassword == "test-password")
            guard case let .failure(partial as DeviceMetricsInventoryError) = containerList() else {
                preconditionFailure("Authenticated container read failure was lost")
            }
            precondition(!partial.requiresAuthorization && partial.partialContainers?.count == 1)
            precondition(provider.inventoryContainerAuthorizationFailures["podman"] == nil)
        }

        // Keep sudoers' executable boundary. NOPASSWD may launch an allowed
        // systemctl successfully even when the service operation itself fails.
        try fixture("sudo", """
        [ "$1" = -n ] || { printf 'unexpected password retry' >&2; exit 4; }
        shift
        [ "$1" = systemctl ] || { printf 'sudoers target changed' >&2; exit 5; }
        export STACIO_TEST_ELEVATED=1
        exec "$@"
        """)
        let serviceBusinessError = "Failed to restart review.service: operation not permitted; try again later"
        try fixture("systemctl", """
        [ "${STACIO_TEST_ELEVATED:-}" = 1 ] || { printf 'permission denied' >&2; exit 1; }
        printf '%s' \(quote(serviceBusinessError)) >&2; exit 1
        """)
        provider.inventoryElevationRequired.removeAll()
        let beforeBusinessFailure = CoreBridge.calls.count
        guard case .failure(DeviceMetricsInventoryError.commandFailed(let serviceDiagnostic)) = try serviceAction() else {
            preconditionFailure("NOPASSWD service failure incorrectly requested sudo authentication")
        }
        precondition(serviceDiagnostic == serviceBusinessError && CoreBridge.calls.count == beforeBusinessFailure + 2)
        precondition(provider.inventorySudoPassword == "test-password", "Service error erased a valid password")
        provider.inventoryElevationRequired.removeAll()
        try fixture("systemctl", "printf 'service is busy; try again later' >&2; exit 1")
        let beforeUnprivilegedRetry = CoreBridge.calls.count
        guard case .failure(DeviceMetricsInventoryError.commandFailed(let busyMessage)) = try serviceAction() else {
            preconditionFailure("An unprivileged business retry message was mistaken for authorization")
        }
        precondition(busyMessage == "service is busy; try again later" && CoreBridge.calls.count == beforeUnprivilegedRetry + 1)
        precondition(provider.inventorySudoPassword == "test-password")
        provider.inventoryElevationRequired.insert("systemctl")
        try fixture("sudo", "printf 'sudo: user is not allowed to execute systemctl as root' >&2; exit 1")
        guard case .failure(DeviceMetricsInventoryError.commandFailed) = try serviceAction() else {
            preconditionFailure("A sudoers policy denial must not request another password")
        }
        precondition(provider.inventorySudoPassword == "test-password")
        for authenticationDiagnostic in [
            "sudo: no password was provided",
            "Sorry, try again.\nsudo: 3 incorrect password attempts"
        ] {
            try fixture("sudo", "printf '%s' \(quote(authenticationDiagnostic)) >&2; exit 1")
            guard case .failure(DeviceMetricsInventoryError.authorizationRequired(let message)) = try serviceAction() else {
                preconditionFailure("A genuine sudo authentication diagnostic lost its retry path")
            }
            precondition(message == authenticationDiagnostic && provider.inventorySudoPassword == nil)
            provider.setInventorySudoPassword("test-password")
        }
        try fixture("sudo", sudoFixture)
        try fixture("podman", "printf 'daemon unavailable' >&2; exit 3")
        guard case let .failure(unavailable as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("A failed daemon must not disappear behind the other engine's rows")
        }
        precondition(unavailable.partialContainers?.count == 1 && !unavailable.requiresAuthorization)
        precondition(unavailable.localizedDescription.contains("Podman：daemon unavailable"))
        try fixture("docker", "printf 'daemon unavailable' >&2; exit 3")
        try fixture("podman", "printf 'permission denied' >&2; exit 1")
        provider.setInventorySudoPassword("wrong-password")
        guard case let .failure(bothFailed as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("Both engines failed")
        }
        precondition(bothFailed.partialContainers == nil && bothFailed.requiresAuthorization)
        precondition(bothFailed.localizedDescription.contains("Docker") && bothFailed.localizedDescription.contains("Podman"))

        // A rootless action failure must not execute against root's unrelated
        // container store or poison the next successful account-level read.
        provider.inventoryContainerReadIdentity.removeAll()
        provider.retryInventoryAuthorization()
        try fixture("docker", "exit 0")
        try fixture("podman", """
        if [ "${STACIO_TEST_ELEVATED:-}" = 1 ]; then
          printf '%s\\n' '{"ID":"cccc","Names":["root-container"],"State":"running","Image":"app"}'
        elif [ "$1" = ps ]; then
          printf '%s\\n' '{"ID":"bbbb","Names":["rootless-container"],"State":"running","Image":"app"}'
        else
          printf 'kill: permission denied' >&2; exit 1
        fi
        """)
        let beforeRootlessMutation = try containerList().get()
        precondition(beforeRootlessMutation.map(\.name) == ["rootless-container"])
        let beforeRootlessAction = CoreBridge.calls.count
        guard case .failure(DeviceMetricsInventoryError.commandFailed) = containerAction() else {
            preconditionFailure("Rootless permission failure changed execution identity")
        }
        precondition(CoreBridge.calls.count == beforeRootlessAction + 1, "Rootless action incorrectly retried through sudo")
        precondition(provider.inventoryContainerReadIdentity["podman"] == false && !provider.inventoryElevationRequired.contains("podman"))
        let afterRootlessMutation = try containerList().get()
        precondition(afterRootlessMutation.map(\.name) == ["rootless-container"])

        // Explicit retry can race an older denial. That older result must not
        // restore the denied-engine cache after the retry generation changes.
        try fixture("podman", "printf 'permission denied' >&2; exit 1")
        for suppliesNewPassword in [false, true] {
            provider.inventoryContainerReadIdentity.removeValue(forKey: "podman")
            provider.inventorySudoPassword = nil
            provider.retryInventoryAuthorization()
            CoreBridge.didReturn = { result in
                if result.stdout.contains("sudo: a password is required") {
                    if suppliesNewPassword { provider.setInventorySudoPassword("test-password") }
                    else { provider.retryInventoryAuthorization() }
                }
            }
            guard case .failure = containerList() else { preconditionFailure("Denied engine unexpectedly succeeded") }
            CoreBridge.didReturn = nil
            precondition(provider.inventoryContainerAuthorizationFailures["podman"] == nil, "Stale denial blocked a newer explicit retry")
            if suppliesNewPassword {
                precondition(provider.inventorySudoPassword == "test-password", "Stale failure erased the newly supplied password")
            }
        }
        provider.inventoryContainerReadIdentity["podman"] = true
        provider.setInventorySudoPassword("wrong-password")
        CoreBridge.didReturn = { result in
            if result.stdout.contains("sudo: 1 incorrect password attempt") { provider.setInventorySudoPassword("test-password") }
        }
        guard case .failure = containerList() else { preconditionFailure("The old elevated request unexpectedly succeeded") }
        CoreBridge.didReturn = nil
        precondition(provider.inventorySudoPassword == "test-password", "Elevated stale failure erased the new password")
        precondition(provider.inventoryContainerAuthorizationFailures["podman"] == nil)

        // sudo-rs uses different LC_ALL=C diagnostics. Exercise the real
        // provider's automatic -n -> -S retry and its per-engine auth cache.
        let sudoRSNoninteractive = "sudo: interactive authentication is required"
        let sudoRSIncorrectPassword = "sudo: Authentication failed, try again.\nsudo: Authentication required but not attempted"
        let sudoRSFixture = """
        if [ "$1" = -n ]; then printf '%s' \(quote(sudoRSNoninteractive)) >&2; exit 1; fi
        [ "$1" = -S ] && [ "$2" = -p ] || exit 2
        shift 3
        IFS= read -r password || exit 2
        if [ "$password" != 'test-password' ]; then printf '%s' \(quote(sudoRSIncorrectPassword)) >&2; exit 1; fi
        export STACIO_TEST_ELEVATED=1
        exec "$@"
        """
        try fixture("sudo", sudoRSFixture)
        try fixture("systemctl", """
        if [ "${STACIO_TEST_ELEVATED:-}" != 1 ]; then printf 'permission denied' >&2; exit 1; fi
        printf 'managed-ok'
        """)
        provider.inventoryElevationRequired.removeAll()
        provider.inventorySudoPassword = nil
        let beforeSudoRSAuthorization = CoreBridge.calls.count
        guard case .failure(DeviceMetricsInventoryError.authorizationRequired(let sudoRSRequired)) = try serviceAction() else {
            preconditionFailure("sudo-rs noninteractive authentication did not request a password")
        }
        precondition(sudoRSRequired == sudoRSNoninteractive && CoreBridge.calls.count == beforeSudoRSAuthorization + 2)
        provider.inventoryElevationRequired.removeAll()
        provider.setInventorySudoPassword("test-password")
        let beforeSudoRSRetry = CoreBridge.calls.count
        try serviceAction().get()
        precondition(CoreBridge.calls.count == beforeSudoRSRetry + 3, "A saved sudo-rs password was not tried after -n failed")
        precondition(CoreBridge.calls.last?.input == "test-password\n")
        precondition(!CoreBridge.calls.last!.command.contains("test-password"), "sudo-rs password leaked into command text")
        provider.setInventorySudoPassword("wrong-password")
        guard case .failure(DeviceMetricsInventoryError.authorizationRequired(let sudoRSWrong)) = try serviceAction() else {
            preconditionFailure("sudo-rs incorrect password did not remain retryable")
        }
        precondition(sudoRSWrong == sudoRSIncorrectPassword && provider.inventorySudoPassword == nil)
        provider.setInventorySudoPassword("test-password")
        try serviceAction().get()
        for authenticationDiagnostic in [
            "sudo: Authentication required but not attempted",
            "sudo: Incorrect authentication attempt",
            "sudo: Authentication failed, try again.\nsudo: maximum 3 incorrect authentication attempts"
        ] {
            try fixture("sudo", "printf '%s' \(quote(authenticationDiagnostic)) >&2; exit 1")
            guard case .failure(DeviceMetricsInventoryError.authorizationRequired(let message)) = try serviceAction() else {
                preconditionFailure("A sudo-rs authentication terminal diagnostic lost its retry path")
            }
            precondition(message == authenticationDiagnostic && provider.inventorySudoPassword == nil)
            provider.setInventorySudoPassword("test-password")
        }
        try fixture("sudo", sudoRSFixture)

        try fixture("docker", #"printf '%s\n' '{"ID":"aaaa","Names":"docker-app","State":"running","Image":"app"}'"#)
        try fixture("podman", """
        if [ "${STACIO_TEST_ELEVATED:-}" != 1 ]; then printf 'permission denied' >&2; exit 1; fi
        printf '%s\\n' '{"ID":"bbbb","Names":["podman-app"],"State":"running","Image":"app"}'
        """)
        provider.inventoryContainerReadIdentity.removeAll()
        provider.inventorySudoPassword = nil
        provider.retryInventoryAuthorization()
        guard case let .failure(sudoRSPartial as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("sudo-rs denied Podman read lost its healthy Docker rows")
        }
        precondition(sudoRSPartial.requiresAuthorization && sudoRSPartial.partialContainers?.map(\.name) == ["docker-app"])
        precondition(provider.inventoryContainerAuthorizationFailures["podman"] != nil)
        let beforeSudoRSHealthyRefresh = CoreBridge.calls.count
        guard case let .failure(sudoRSCached as DeviceMetricsInventoryError) = containerList() else {
            preconditionFailure("sudo-rs denied engine cache was lost")
        }
        precondition(sudoRSCached.requiresAuthorization && sudoRSCached.partialContainers?.map(\.name) == ["docker-app"])
        precondition(CoreBridge.calls.count == beforeSudoRSHealthyRefresh + 2, "sudo-rs denied engine blocked healthy polling or retried automatically")
        provider.setInventorySudoPassword("test-password")
        let sudoRSRecovered = try containerList().get()
        precondition(Set(sudoRSRecovered.map(\.engine)) == ["docker", "podman"])
        precondition(provider.inventoryContainerReadIdentity == ["docker": false, "podman": true])

        for businessError in [
            "OCI runtime create failed: permission denied",
            "application log: sudo: interactive authentication is required",
            "sudo: interactive authentication is required while restoring application state",
            "application log: sudo: maximum 3 incorrect authentication attempts",
            "sudo: maximum 3 incorrect authentication attempts recorded by application",
            "application log: sudo: Authentication required but not attempted",
            "sudo: Authentication required but not attempted by this application",
            "application log: sudo: Incorrect authentication attempt",
            "sudo: Incorrect authentication attempt recorded by application",
            "interactive authentication is required",
            "maximum 3 incorrect authentication attempts",
            "Authentication required but not attempted",
            "Incorrect authentication attempt"
        ] {
            try fixture("podman", "printf '%s' \(quote(businessError)) >&2; exit 1")
            guard case .failure(DeviceMetricsInventoryError.commandFailed(let message)) = containerAction() else {
                preconditionFailure("sudo-rs business diagnostic incorrectly requested another password")
            }
            precondition(message == businessError && provider.inventorySudoPassword == "test-password")
            guard case let .failure(partial as DeviceMetricsInventoryError) = containerList() else {
                preconditionFailure("sudo-rs authenticated read failure was lost")
            }
            precondition(!partial.requiresAuthorization && partial.partialContainers?.count == 1)
            precondition(provider.inventoryContainerAuthorizationFailures["podman"] == nil)
        }

        // An older sudo-rs denial must neither erase a newly entered password
        // nor reinsert the denied-engine cache after that password's generation.
        provider.inventoryContainerReadIdentity.removeValue(forKey: "podman")
        provider.inventorySudoPassword = nil
        provider.retryInventoryAuthorization()
        try fixture("podman", "printf 'permission denied' >&2; exit 1")
        CoreBridge.didReturn = { result in
            if result.stdout == sudoRSNoninteractive { provider.setInventorySudoPassword("test-password") }
        }
        guard case .failure = containerList() else { preconditionFailure("The old sudo-rs noninteractive request unexpectedly succeeded") }
        CoreBridge.didReturn = nil
        precondition(provider.inventorySudoPassword == "test-password")
        precondition(provider.inventoryContainerAuthorizationFailures["podman"] == nil)
        provider.inventoryContainerReadIdentity["podman"] = true
        provider.setInventorySudoPassword("wrong-password")
        CoreBridge.didReturn = { result in
            if result.stdout == sudoRSIncorrectPassword { provider.setInventorySudoPassword("test-password") }
        }
        guard case .failure = containerList() else { preconditionFailure("The old sudo-rs password request unexpectedly succeeded") }
        CoreBridge.didReturn = nil
        precondition(provider.inventorySudoPassword == "test-password", "sudo-rs stale failure erased the new password")
        precondition(provider.inventoryContainerAuthorizationFailures["podman"] == nil)

        // Exercise format negotiation through the real provider and bounded
        // shell, including minimal ps builds that silently ignore all options.
        let filesBeforeProcessChecks = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        provider.inventorySudoPassword = nil
        let processCounters = directory.appendingPathComponent("proc-counters")
        for pid in [21, 22] {
            try FileManager.default.createDirectory(at: processCounters.appendingPathComponent(String(pid)), withIntermediateDirectories: true)
        }
        try "MemTotal: 10000 kB\n".write(to: processCounters.appendingPathComponent("meminfo"), atomically: true, encoding: .utf8)
        for pid in [21, 22] {
            try "VmRSS: 250 kB\n".write(to: processCounters.appendingPathComponent("\(pid)/status"), atomically: true, encoding: .utf8)
        }
        func counterFixture(total: UInt64, workerUser: UInt64, workerSystem: UInt64) throws {
            try "cpu \(total) 0 0 0 0 0 0 0\ncpu0 1 1 1 1\ncpu1 1 1 1 1\ncpu2 1 1 1 1\ncpu3 1 1 1 1\nbtime 100\n"
                .write(to: processCounters.appendingPathComponent("stat"), atomically: true, encoding: .utf8)
            for (pid, user, system) in [(21, UInt64(100), UInt64(10)), (22, workerUser, workerSystem)] {
                var fields = Array(repeating: "0", count: 22)
                fields[0] = "R"
                fields[11] = String(user)
                fields[12] = String(system)
                fields[19] = String(pid * 10)
                try ("\(pid) (worker (socket)) " + fields.joined(separator: " ") + "\n")
                    .write(to: processCounters.appendingPathComponent("\(pid)/stat"), atomically: true, encoding: .utf8)
            }
        }
        func processList() -> Result<[ManagedProcessInfo], Error> {
            var result: Result<[ManagedProcessInfo], Error>?
            provider.listManagedProcesses { result = $0 }
            let deadline = Date().addingTimeInterval(8)
            while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            guard let result else { preconditionFailure("Process list did not complete") }
            return result
        }
        try fixture("ps", "printf '%s\\n' '21 root 1356 S /sbin/procd' '22 1000 2048 R /bin/worker --seek 00:10'")
        try fixture("top", "printf '%s\\n' 'PID PPID USER STAT VSZ %VSZ %CPU COMMAND' '21 1 root S 1356 1% 0% /sbin/procd' '22 1 1000 R 2048 2% 7% /bin/worker --seek 00:10'")
        CoreBridge.processCounterFixturePath = processCounters.path
        try counterFixture(total: 1000, workerUser: 100, workerSystem: 20)
        let firstProcesses = try processList().get()
        precondition(firstProcesses.map(\.pid) == [21, 22] && firstProcesses.allSatisfy { !$0.hasCPUUsage && $0.cpuPercent == 0 },
                     "The first interval sample must not publish top's lifetime percentages")
        precondition(firstProcesses.map(\.processIdentity) == ["100:210", "100:220"], "Collectors did not capture consistent process births")
        precondition(firstProcesses.allSatisfy { $0.hasMemoryUsage && $0.memoryPercent == 2.5 && $0.residentBytes == 256000 }, "BusyBox VSZ was not replaced by measured RSS")
        try counterFixture(total: 1400, workerUser: 304, workerSystem: 30)
        let measuredProcesses = try processList().get()
        precondition(measuredProcesses.allSatisfy(\.hasCPUUsage))
        precondition(measuredProcesses.map(\.pid) == [21, 22] && measuredProcesses[0].cpuPercent == 0
                     && abs(measuredProcesses[1].cpuPercent - 53.5) < 0.0001,
                     "CPU must use 214 process ticks / 400 aggregate ticks, not top's 7% or a per-core 214%")
        // Execute the actual guard against a local proc-shaped fixture. The
        // local renice stub records invocation and never changes a real PID.
        let mutationLog = directory.appendingPathComponent("mutation-log")
        try fixture("renice", "printf '%s\\n' \"$*\" >> " + quote(mutationLog.path))
        let guardedMutation = try DeviceMetricsInventoryCommands.checkedProcess(.renice(5), pid: 22, expectedIdentity: "100:220")
            .replacingOccurrences(of: "/proc/", with: processCounters.path + "/")
        let matching = try run(guardedMutation)
        precondition(matching.exitCode == 0 && FileManager.default.fileExists(atPath: mutationLog.path))
        try FileManager.default.removeItem(at: mutationLog)
        let statPath = processCounters.appendingPathComponent("22/stat")
        let oldStat = try String(contentsOf: statPath, encoding: .utf8)
        try oldStat.replacingOccurrences(of: " 220 ", with: " 221 ").write(to: statPath, atomically: true, encoding: .utf8)
        let reused = try run(guardedMutation)
        precondition(reused.exitCode != 0 && reused.stdout.contains("身份已变化") && !FileManager.default.fileExists(atPath: mutationLog.path), "Reused PID reached the mutation")
        try FileManager.default.removeItem(at: statPath)
        let disappeared = try run(guardedMutation)
        precondition(disappeared.exitCode != 0 && !FileManager.default.fileExists(atPath: mutationLog.path), "Unverifiable PID reached the mutation")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("renice"))
        try counterFixture(total: 1800, workerUser: 400, workerSystem: 40)
        // Reuse between ps and the final observation must not attach a new
        // process birth to the old row.
        try fixture("top", "sed 's/ 220 / 221 /' " + quote(statPath.path) + " > " + quote(statPath.path + ".new") + "; mv " + quote(statPath.path + ".new") + " " + quote(statPath.path) + "; printf '%s\\n' 'PID PPID USER STAT VSZ %VSZ %CPU COMMAND' '22 1 root R 2048 2% 7% old-worker'")
        let changing = try processList().get()
        precondition(changing.count == 1 && changing[0].processIdentity == nil && !changing[0].hasMemoryUsage, "A birth captured only after collection legalized an old row")
        CoreBridge.processCounterFixturePath = nil
        try fixture("top", "exit 1")
        let basicProcesses = try processList().get()
        precondition(basicProcesses.map(\.pid) == [21, 22] && basicProcesses.allSatisfy { !$0.hasCPUUsage })
        precondition(basicProcesses[1].user == "1000" && basicProcesses[1].command == "/bin/worker --seek 00:10")
        let supportedHeader = """
        for argument do
          case "$argument" in pid=*) pid_header="${argument#pid=}";; esac
        done
        [ -n "$pid_header" ] || exit 2
        printf '  %s   \\n' "$pid_header"
        """
        try fixture("ps", supportedHeader + "\nprintf '%s\\n' '31 1 root R 4.5 6.2 10 20 00:01 worker --seek 00:10'")
        let fullProcesses = try processList().get()
        precondition(fullProcesses.count == 1 && fullProcesses[0].pid == 31 && fullProcesses[0].cpuPercent == 0)
        precondition(!fullProcesses[0].hasCPUUsage && fullProcesses[0].command == "worker --seek 00:10",
                     "A full ps row without interval counters must not expose lifetime CPU")
        try fixture("ps", supportedHeader + "\nprintf '%s\\n' '31 1 root R nan 6.2 10 20 00:01 worker'")
        guard case .failure(DeviceMetricsInventoryError.invalidResponse) = processList() else {
            preconditionFailure("Malformed full-ps data bypassed strict parsing")
        }
        for name in ["ps", "top"] { try FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        try FileManager.default.removeItem(at: processCounters)
        let filesAfterProcessChecks = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        precondition(filesBeforeProcessChecks == filesAfterProcessChecks, "Process collectors left scratch files behind")

        // Executables found through the account's PATH must remain available
        // after sudo applies a restrictive secure_path. The path includes shell
        // metacharacters so quoting is checked as argv, not just by inspection.
        let engineDirectory = directory.appendingPathComponent("engine bin ' $value")
        try FileManager.default.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
        let engineActionLog = directory.appendingPathComponent("engine-action.log")
        for engine in ["docker", "podman"] {
            let id = engine == "docker" ? "aaaa" : "bbbb"
            let body = """
            #!/bin/sh
            [ "$1" != --version ] || { printf 'Docker version 28.0\\n'; exit 0; }
            [ "${STACIO_TEST_ELEVATED:-}" = 1 ] || { printf 'permission denied' >&2; exit 1; }
            if [ "$1" = ps ]; then
              printf '%s\\n' '{"ID":"\(id)","Names":"\(engine)-secure-path","State":"running"}'
            else
              printf '%s\\n' "$0" "$@" >> \(quote(engineActionLog.path))
            fi
            """
            let executable = engineDirectory.appendingPathComponent(engine)
            try body.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try fixture("sudo", """
        if [ "$1" = -n ]; then printf 'sudo: a password is required\\n' >&2; exit 1; fi
        [ "$1" = -S ] && [ "$2" = -p ] && [ "$3" = '' ] || exit 92
        shift 3
        IFS= read -r supplied || exit 93
        [ "$supplied" = test-password ] || exit 94
        # A restricted sudoers policy permits the engine, not an arbitrary sh.
        case "$1" in \(quote(engineDirectory.path))/*) ;; *) printf 'sudoers target changed' >&2; exit 95 ;; esac
        exec /usr/bin/env -i PATH=/usr/bin:/bin STACIO_TEST_ELEVATED=1 "$@"
        """)
        let priorPath = environment["PATH"]!
        environment["PATH"] = engineDirectory.path + ":" + priorPath
        CoreBridge.environment = environment
        provider.inventoryContainerReadIdentity.removeAll()
        provider.retryInventoryAuthorization()
        provider.setInventorySudoPassword("test-password")
        let beforeSecurePath = CoreBridge.calls.count
        let securePathRows = try containerList().get()
        precondition(Set(securePathRows.map(\.name)) == ["docker-secure-path", "podman-secure-path"])
        precondition(provider.inventoryContainerReadIdentity == ["docker": true, "podman": true], "Logical engine identity changed into a filesystem path")
        try containerAction().get()
        let executedEngine = try String(contentsOf: engineActionLog, encoding: .utf8)
        precondition(executedEngine == engineDirectory.appendingPathComponent("podman").path + "\nstop\nbbbb\n", "secure_path or shell quoting changed the executable argv")
        precondition(CoreBridge.calls[beforeSecurePath...].allSatisfy { !$0.command.contains("test-password") }, "Password leaked into an encoded command")
        environment["PATH"] = priorPath
        CoreBridge.environment = environment

        // Both watchdog paths run the actual privileged collectors after a
        // sudo env_reset. The same-UID supervisor must own and clean a private
        // 0700 directory outside the caller's scratch, including after SIGKILL.
        // This fixture simulates sudo's environment, not an actual root login.
        let setsidHelper = ProcessInfo.processInfo.environment["STACIO_TEST_SETSID_HELPER"]!
        let sudoFallback = directory.appendingPathComponent("sudo-fallback-tmp")
        try FileManager.default.createDirectory(at: sudoFallback, withIntermediateDirectories: true)
        for grouped in [false, true] {
            if grouped {
                try FileManager.default.copyItem(atPath: setsidHelper, toPath: directory.appendingPathComponent("setsid").path)
            }
            let childFile = directory.appendingPathComponent("child-\(grouped)")
            let metadata = directory.appendingPathComponent("scratch-metadata-\(grouped)")
            let executable = grouped ? "ss" : "ps"
            try fixture(executable, """
            [ -n "${STACIO_COMMAND_TMPDIR:-}" ] || exit 96
            printf '%s\\n' "$STACIO_COMMAND_TMPDIR" > \(quote(metadata.path))
            /usr/bin/stat -f '%u:%Lp' "$STACIO_COMMAND_TMPDIR" >> \(quote(metadata.path))
            for file in "$STACIO_COMMAND_TMPDIR/out" "$STACIO_COMMAND_TMPDIR/identity" "$STACIO_COMMAND_TMPDIR/err" "$STACIO_COMMAND_TMPDIR/results" "$STACIO_COMMAND_TMPDIR/errors"; do
              [ -f "$file" ] || continue
              # Parent cleanup must unlink directly; it must not need to read
              # or chmod a root-owned file after the collector was killed.
              chmod 000 "$file"
            done
            /usr/bin/stat -f '%Lp' "$STACIO_COMMAND_TMPDIR/out" >> \(quote(metadata.path))
            sleep 60 & child=$!; printf '%s' "$child" > \(quote(childFile.path)); wait
            """)
            try fixture("sudo", """
            [ "$1" = -S ] && [ "$2" = -p ] && [ "$3" = '' ] || exit 92
            shift 3
            IFS= read -r supplied || exit 93
            [ "$supplied" = test-password ] || exit 94
            [ "$#" = 6 ] && [ "$1" = sh ] && [ "$2" = -c ] && [ "$4" = stacio-supervisor ] || exit 95
            exec /usr/bin/env -i PATH=\(quote(priorPath)) TMPDIR=\(quote(sudoFallback.path)) "$@"
            """)
            let collector = grouped ? DeviceMetricsInventoryCommands.ports : DeviceMetricsInventoryCommands.processes
            let command = "sudo -S -p '' " + DeviceMetricsInventoryCommands.privilegedCollector(collector)
            precondition(DeviceMetricsInventoryCommands.boundedRemoteCommand(command).utf8.count + 18 < 32 * 1024, "Privileged collector exceeded SSH wire budget")
            let began = Date()
            let result = try run(command, input: "test-password\n")
            let elapsed = Date().timeIntervalSince(began)
            precondition(result.exitCode == 124 && elapsed >= 21 && elapsed < 25, "Privileged deadline did not leave a cleanup margin before the outer watchdog: \(elapsed), \(result.exitCode)")
            try FileManager.default.removeItem(at: directory.appendingPathComponent(executable))
            let values = try String(contentsOf: metadata, encoding: .utf8).split(separator: "\n").map(String.init)
            precondition(values.count == 3 && values[1] == "\(getuid()):700" && values[2] == "0", "Scratch ownership or permission setup changed: \(values)")
            precondition(values[0].hasPrefix("/tmp/stacio-privileged.") && !values[0].hasPrefix(directory.path), "Privileged scratch trusted caller-owned TMPDIR")
            precondition(!FileManager.default.fileExists(atPath: values[0]), "Privileged supervisor did not remove scratch after SIGKILL")
            let fallbackFiles = try FileManager.default.contentsOfDirectory(atPath: sudoFallback.path)
            precondition(fallbackFiles.isEmpty, "env_reset caused a separate privileged temporary directory")
            let child = try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let childState = try runShell("/bin/ps -o stat= -p \(child)", environment: environment)
            precondition(childState.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || childState.stdout.contains("Z"), "Watchdog left its sleep descendant running")
            let groupedStdin = try run("IFS= read -r value; [ \"$value\" = yes ] && printf ok", input: "yes\n")
            precondition(groupedStdin.exitCode == 0 && groupedStdin.stdout == "ok")

            // An abnormal collector exit still leaves its same-UID supervisor
            // alive to remove scratch. Where setsid is available, even a
            // surviving background child must be killed after leader exit.
            for killed in [false, true] {
                let shortCollector = """
                printf '%s' "$STACIO_COMMAND_TMPDIR" > \(quote(metadata.path))
                touch "$STACIO_COMMAND_TMPDIR/partial"; chmod 000 "$STACIO_COMMAND_TMPDIR/partial"
                \(grouped ? "sleep 60 & child=$!; printf '%s' \"$child\" > " + quote(childFile.path) : ":")
                \(killed ? "kill -KILL $$" : "exit 0")
                """
                let shortResult = try run("sudo -S -p '' " + DeviceMetricsInventoryCommands.privilegedCollector(shortCollector), input: "test-password\n")
                precondition(killed ? shortResult.exitCode != 0 : shortResult.exitCode == 0)
                let shortPath = try String(contentsOf: metadata, encoding: .utf8)
                precondition(!FileManager.default.fileExists(atPath: shortPath), "Collector exit skipped supervisor scratch cleanup")
                if grouped {
                    let orphan = try String(contentsOf: childFile, encoding: .utf8)
                    let orphanState = try runShell("/bin/ps -o stat= -p \(orphan)", environment: environment)
                    precondition(orphanState.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || orphanState.stdout.contains("Z"), "Exited collector left its process group alive")
                }
            }

            for (deadline, status): (String, Int32) in [("1", 124), ("invalid", 125)] {
                let expired = try run("export STACIO_COMMAND_DEADLINE=" + quote(deadline) + "; " + command, input: "test-password\n")
                precondition(expired.exitCode == status, "Expired or invalid cross-sudo deadline started a collector")
            }

            // The deadline also covers sudo/PAM before the collector starts.
            // Shorten only the fixture's timer, leaving the production wrapper
            // and its group/tree termination paths otherwise unchanged.
            try fixture("sudo", "sleep 60 & child=$!; printf '%s' \"$child\" > " + quote(childFile.path) + "; wait")
            let authenticationCommand = DeviceMetricsInventoryCommands.boundedRemoteCommand(command)
                .replacingOccurrences(of: "sleep 25;", with: "sleep 1;")
                .replacingOccurrences(of: "timeout 25s", with: "timeout 1s")
            let authenticationBegan = Date()
            let authenticationResult = try runShell(authenticationCommand, input: "test-password\n", environment: environment)
            precondition(authenticationResult.exitCode != 0 && Date().timeIntervalSince(authenticationBegan) < 6, "sudo authentication escaped the request deadline")
            let authenticationChild = try String(contentsOf: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let authenticationState = try runShell("/bin/ps -o stat= -p \(authenticationChild)", environment: environment)
            precondition(authenticationState.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authenticationState.stdout.contains("Z"), "Authentication watchdog left its child running")
        }
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(remainingFiles.allSatisfy { !$0.hasPrefix("stacio-command.") })
        print("Command checks passed: secure_path absolute executable argv, sudo env_reset private supervisor scratch ownership/permissions, process format negotiation, real procfs fixture CPU intervals, strict parsing, stdin, sudo/sudo-rs authorization retries, container identity, healthy partial polling, stale credentials, diagnostics, 25-second fallback/group watchdogs, temporary-file cleanup")
    }
}
