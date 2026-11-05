import Foundation

struct RemoteCommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}
struct AuthorizationCheckContext {
    let config: Void = ()
    let secret: Void = ()
    let expectedFingerprintSHA256: Void = ()
}
public final class CoreBridgeDeviceMetricsProvider {
    let context = AuthorizationCheckContext()
    let inventoryWorkerQueue = DispatchQueue(label: "inventory-auth-check", attributes: .concurrent)
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
private enum TestTransportError: Error { case disconnected }
private struct ExpectedCall {
    let command: String
    let password: String?
    let output: String
    let exitCode: Int32
    let beforeReturn: (() -> Void)?
    let transportError: Bool
    init(_ command: String, password: String? = nil, output: String = "", exitCode: Int32 = 0,
         beforeReturn: (() -> Void)? = nil, transportError: Bool = false) {
        self.command = command; self.password = password; self.output = output; self.exitCode = exitCode
        self.beforeReturn = beforeReturn; self.transportError = transportError
    }
}
enum CoreBridge {
    private static let lock = NSLock()
    private static var expected: [ExpectedCall] = []
    private(set) static var count = 0
    fileprivate static func expect(_ calls: [ExpectedCall]) {
        lock.lock(); defer { lock.unlock() }
        precondition(expected.isEmpty, "An earlier operation skipped expected calls")
        expected = calls
    }
    static func assertDrained() {
        lock.lock(); defer { lock.unlock() }
        precondition(expected.isEmpty, "Expected transport call was not made")
    }
    static func runLiveRemoteCommand(config: Void, secret: Void, expectedFingerprintSHA256: Void,
                                     command: String, standardInput: String?) throws -> RemoteCommandResult {
        lock.lock()
        precondition(!expected.isEmpty, "Unexpected operation or extra authorization probe")
        let next = expected.removeFirst()
        count += 1
        lock.unlock()
        precondition(command == DeviceMetricsInventoryCommands.boundedRemoteCommand(next.command), "Wrong operation identity or validation command")
        precondition(command.utf8.count + 18 < 32 * 1024)
        precondition(standardInput == next.password.map { $0 + "\n" })
        if let password = next.password {
            precondition(!command.contains(password), "Password leaked into command arguments")
        }
        next.beforeReturn?()
        if next.transportError { throw TestTransportError.disconnected }
        return RemoteCommandResult(stdout: next.output, stderr: "", exitCode: next.exitCode)
    }
}

@main
struct AuthorizationChecks {
    static func main() throws {
        let validate = "sudo -k -S -p '' -v"
        let identity = "1700000000:200"
        let checkedPause = try DeviceMetricsInventoryCommands.checkedProcess(.pause, pid: 444, expectedIdentity: identity)
        let password = "auth-fixture-'\"$-secret"
        let wrong = "incorrect-fixture-secret"
        let authFailure = "sudo: 1 incorrect password attempt"
        func wait<T>(_ action: (@escaping (Result<T, Error>) -> Void) -> Void) -> Result<T, Error> {
            var value: Result<T, Error>?
            action { value = $0 }
            let deadline = Date().addingTimeInterval(4)
            while value == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
            guard let value else { preconditionFailure("Operation did not complete") }
            CoreBridge.assertDrained()
            return value
        }
        func authorize(_ provider: CoreBridgeDeviceMetricsProvider, _ password: String) -> Result<Void, Error> {
            wait { provider.authorizeInventorySudo(password, completion: $0) }
        }
        func requireAuthenticationFailure<T>(_ result: Result<T, Error>) {
            guard case .failure(let error as DeviceMetricsInventoryError) = result else {
                preconditionFailure("Expected a typed authentication failure")
            }
            precondition(error.requiresAuthorization)
        }
        let provider = CoreBridgeDeviceMetricsProvider()
        provider.inventoryContainerReadIdentity["podman"] = false
        provider.inventoryContainerAuthorizationFailures["docker"] = .authorizationRequired("denied")
        let rejectedPortRead = provider.inventoryPortOwnershipState.begin()
        provider.inventoryPortOwnershipState.complete(rejectedPortRead.generation, preferElevation: false,
                                                     failure: .authorizationRequired("denied"))
        CoreBridge.expect([ExpectedCall(validate, password: password)])
        try authorize(provider, password).get()
        precondition(provider.inventorySudoPassword == password && provider.inventoryContainerAuthorizationFailures.isEmpty)
        precondition(provider.inventoryPortOwnershipState.begin().failure == nil)
        precondition(provider.inventoryContainerReadIdentity["podman"] == false && provider.inventoryElevationRequired.isEmpty,
                     "Validation must not force every operation or rootless store to root")

        // One validation shares the same credential with every manager while
        // preserving each command's own authorization and execution identity.
        provider.inventoryElevationRequired = ["kill", "systemctl"]
        CoreBridge.expect([ExpectedCall("sudo -S -p '' " + checkedPause, password: password)])
        try wait { provider.performProcessAction(.pause, pid: 444, expectedIdentity: identity, completion: $0) }.get()
        CoreBridge.expect([ExpectedCall("sudo -S -p '' systemctl --no-ask-password stop -- 'app.service'", password: password)])
        try wait { provider.performServiceAction(.stop, name: "app.service", scope: "system", completion: $0) }.get()
        let processOutput = "__STACIO_PROCESS_FULL_PS__\n444 1 root S 0 1 1024 2048 00:01 root-only-worker"
        CoreBridge.expect([ExpectedCall("sudo -S -p '' " + DeviceMetricsInventoryCommands.privilegedCollector(DeviceMetricsInventoryCommands.processes), password: password, output: processOutput)])
        let privilegedProcesses = try wait { provider.listManagedProcesses(completion: $0) }.get()
        precondition(privilegedProcesses.first?.user == "root", "Shared sudo was not applied to process reads")
        CoreBridge.expect([])
        guard case .failure = wait({ provider.performProcessAction(.terminate, pid: 444, completion: $0) }) else {
            preconditionFailure("The legacy PID-only action bypassed identity verification")
        }
        let anonymous = "__STACIO_PORTS_BEGIN__\n__STACIO_PORT_UID__=1000\n__STACIO_SS__\n__STACIO_IPV4__\ntcp LISTEN 0 128 *:80 *:*\n__STACIO_PORTS_END__"
        let ownershipBefore = "__STACIO_IDENTITIES_BEFORE__\nboot 1700000000 0\n8080 50 -\n__STACIO_IDENTITIES_END__\n"
        let ownershipAfter = "\n__STACIO_IDENTITIES_AFTER__\nboot 1700000000 0\n8080 50 -\n__STACIO_IDENTITIES_END__"
        let owned = ownershipBefore + anonymous.replacingOccurrences(of: "=1000", with: "=0")
            .replacingOccurrences(of: "*:80 *:*", with: "*:80 *:* users:((\"httpd\",pid=8080,fd=4))") + ownershipAfter
        CoreBridge.expect([ExpectedCall(DeviceMetricsInventoryCommands.ports, output: anonymous),
            ExpectedCall("sudo -S -p '' " + DeviceMetricsInventoryCommands.privilegedCollector(DeviceMetricsInventoryCommands.ports),
                         password: password, output: owned)])
        let ports = try wait { provider.listManagedPorts(completion: $0) }.get()
        precondition(ports.first?.pid == 8080 && ports.first?.processIdentity == "1700000000:50")
        let reusedOwner = owned.replacingOccurrences(of: ownershipAfter, with: ownershipAfter.replacingOccurrences(of: "8080 50", with: "8080 51"))
        precondition(DeviceMetricsInventoryParser.ports(reusedOwner).first?.processIdentity == nil, "Reused socket owner became a valid target")
        let engines = DeviceMetricsInventoryCommands.containerEngines
        let dockerBase = "docker ps -a --no-trunc --format '{{json .}}'"
        let podmanBase = "podman ps -a --no-trunc --format '{{json .}}'"
        let docker = try DeviceMetricsInventoryCommands.resolvedContainerCommand(dockerBase, engine: "docker", elevated: false, usesPassword: false)
        let dockerSudoN = try DeviceMetricsInventoryCommands.resolvedContainerCommand(dockerBase, engine: "docker", elevated: true, usesPassword: false)
        let dockerSudoS = try DeviceMetricsInventoryCommands.resolvedContainerCommand(dockerBase, engine: "docker", elevated: true, usesPassword: true)
        let podman = try DeviceMetricsInventoryCommands.resolvedContainerCommand(podmanBase, engine: "podman", elevated: false, usesPassword: false)
        CoreBridge.expect([ExpectedCall(engines, output: "docker\npodman\n"),
            ExpectedCall(docker, output: "permission denied", exitCode: 1),
            ExpectedCall(dockerSudoN, output: "sudo: a password is required", exitCode: 1),
            ExpectedCall(dockerSudoS, password: password, output: "{\"ID\":\"aaaa\",\"Names\":\"docker-system\",\"State\":\"running\"}"),
            ExpectedCall(podman, output: "{\"ID\":\"bbbb\",\"Names\":\"podman-user\",\"State\":\"running\"}")])
        let containers = try wait { provider.listManagedContainers(completion: $0) }.get()
        precondition(Set(containers.map(\.name)) == ["docker-system", "podman-user"])
        precondition(provider.inventoryContainerReadIdentity == ["docker": true, "podman": false])
        CoreBridge.expect([ExpectedCall(try DeviceMetricsInventoryCommands.resolvedContainerCommand("podman stop 'bbbb'", engine: "podman", elevated: false, usesPassword: false), output: "permission denied", exitCode: 1)])
        guard case .failure(let rootlessError as DeviceMetricsInventoryError) = wait({ provider.performContainerAction(.stop, id: "bbbb", engine: "podman", completion: $0) }) else {
            preconditionFailure("Rootless mutation unexpectedly succeeded")
        }
        precondition(!rootlessError.requiresAuthorization && provider.inventoryContainerReadIdentity["podman"] == false)
        CoreBridge.expect([ExpectedCall("systemctl --user --no-ask-password restart -- 'user.service'")])
        try wait { provider.performServiceAction(.restart, name: "user.service", scope: "user", completion: $0) }.get()

        // Invalid/rejected credentials never become shared state, including a
        // byte-length overflow made from multibyte characters.
        let other = CoreBridgeDeviceMetricsProvider()
        precondition(other.inventorySudoPassword == nil, "Credentials escaped their provider/session")
        for candidate in ["", "first\nsecond", "first\rsecond", "null\0byte", String(repeating: "界", count: 1400)] {
            CoreBridge.expect([])
            guard case .failure(DeviceMetricsInventoryError.invalidArgument) = authorize(other, candidate) else {
                preconditionFailure("Invalid password reached the remote command")
            }
        }
        CoreBridge.expect([ExpectedCall(validate, password: wrong, output: authFailure, exitCode: 1)])
        requireAuthenticationFailure(authorize(other, wrong))
        precondition(other.inventorySudoPassword == nil)
        CoreBridge.expect([ExpectedCall(validate, password: wrong, output: authFailure, exitCode: 1)])
        requireAuthenticationFailure(authorize(provider, wrong))
        precondition(provider.inventorySudoPassword == password, "Failed validation replaced a working credential")
        CoreBridge.expect([ExpectedCall(validate, password: wrong, transportError: true)])
        guard case .failure(TestTransportError.disconnected) = authorize(provider, wrong) else {
            preconditionFailure("Transport failure was mislabeled as a wrong password")
        }
        precondition(provider.inventorySudoPassword == password)
        CoreBridge.expect([ExpectedCall(validate, password: wrong, output: "sudo: user may not run sudo", exitCode: 1)])
        guard case .failure(let policyError as DeviceMetricsInventoryError) = authorize(provider, wrong) else {
            preconditionFailure("Policy denial was lost")
        }
        precondition(!policyError.requiresAuthorization && provider.inventorySudoPassword == password)

        // A delayed old validation cannot overwrite a newer completed one.
        let concurrent = CoreBridgeDeviceMetricsProvider()
        let oldStarted = DispatchSemaphore(value: 0), releaseOld = DispatchSemaphore(value: 0)
        var oldResult: Result<Void, Error>?
        CoreBridge.expect([ExpectedCall(validate, password: "old-fixture", beforeReturn: {
            oldStarted.signal(); precondition(releaseOld.wait(timeout: .now() + 4) == .success)
        }), ExpectedCall(validate, password: "new-fixture")])
        concurrent.authorizeInventorySudo("old-fixture") { oldResult = $0 }
        precondition(oldStarted.wait(timeout: .now() + 4) == .success)
        try authorize(concurrent, "new-fixture").get()
        releaseOld.signal()
        let oldDeadline = Date().addingTimeInterval(4)
        while oldResult == nil && Date() < oldDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard case .failure? = oldResult else { preconditionFailure("Superseded validation succeeded") }
        precondition(concurrent.inventorySudoPassword == "new-fixture")

        // Even equal strings have different generations. An operation begun
        // with an old credential may not erase the newly validated same value.
        let same = "same-fixture-secret"
        concurrent.setInventorySudoPassword(same)
        concurrent.inventoryElevationRequired.insert("kill")
        let oldCommandStarted = DispatchSemaphore(value: 0), releaseCommand = DispatchSemaphore(value: 0)
        var commandResult: Result<Void, Error>?
        CoreBridge.expect([ExpectedCall("sudo -S -p '' " + checkedPause, password: same, output: authFailure, exitCode: 1, beforeReturn: {
            oldCommandStarted.signal(); precondition(releaseCommand.wait(timeout: .now() + 4) == .success)
        }), ExpectedCall(validate, password: same)])
        concurrent.performProcessAction(.pause, pid: 444, expectedIdentity: identity) { commandResult = $0 }
        precondition(oldCommandStarted.wait(timeout: .now() + 4) == .success)
        try authorize(concurrent, same).get()
        releaseCommand.signal()
        let commandDeadline = Date().addingTimeInterval(4)
        while commandResult == nil && Date() < commandDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard let commandResult else { preconditionFailure("Old command did not finish") }
        requireAuthenticationFailure(commandResult)
        precondition(concurrent.inventorySudoPassword == same, "A stale failure erased a newer equal credential")

        // A command can also begin after validation starts but before its
        // password is published. It still owns the previous credential epoch.
        let validationStarted = DispatchSemaphore(value: 0), releaseValidation = DispatchSemaphore(value: 0)
        let pendingCommandStarted = DispatchSemaphore(value: 0), releasePendingCommand = DispatchSemaphore(value: 0)
        var validationResult: Result<Void, Error>?, pendingCommandResult: Result<Void, Error>?
        CoreBridge.expect([ExpectedCall(validate, password: same, beforeReturn: {
            validationStarted.signal(); precondition(releaseValidation.wait(timeout: .now() + 4) == .success)
        }), ExpectedCall("sudo -S -p '' " + checkedPause, password: same, output: authFailure, exitCode: 1, beforeReturn: {
            pendingCommandStarted.signal(); precondition(releasePendingCommand.wait(timeout: .now() + 4) == .success)
        })])
        concurrent.authorizeInventorySudo(same) { validationResult = $0 }
        precondition(validationStarted.wait(timeout: .now() + 4) == .success)
        concurrent.performProcessAction(.pause, pid: 444, expectedIdentity: identity) { pendingCommandResult = $0 }
        precondition(pendingCommandStarted.wait(timeout: .now() + 4) == .success)
        releaseValidation.signal()
        let validationDeadline = Date().addingTimeInterval(4)
        while validationResult == nil && Date() < validationDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard case .success? = validationResult else { preconditionFailure("Latest validation did not succeed") }
        releasePendingCommand.signal()
        let pendingDeadline = Date().addingTimeInterval(4)
        while pendingCommandResult == nil && Date() < pendingDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        guard let pendingCommandResult else { preconditionFailure("Command begun during validation did not finish") }
        requireAuthenticationFailure(pendingCommandResult)
        precondition(concurrent.inventorySudoPassword == same, "A command begun during validation erased the published equal credential")
        CoreBridge.assertDrained()
        print("Authorization checks passed: \(CoreBridge.count) bounded calls; one validation shared across managers, stdin-only credentials, invalid/wrong password, transport/policy errors, session isolation, preserved rootless/user scope, overlapping validations and equal-password generation protection")
    }
}
