import Darwin
import Foundation

public enum LocalAgentAuthenticationProbeState: String, Codable, Equatable, Sendable {
    case authenticated
    case needsLogin
    case unknown
}

public enum LocalAgentProbePhase: String, Equatable, Sendable {
    case version
    case loginStatus
}

public struct LocalAgentProbeExecutionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool
    public let outputTruncated: Bool

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool = false,
        outputTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.outputTruncated = outputTruncated
    }
}

public enum LocalAgentProbeExecutionError: Error, Equatable {
    case invalidExecutable
    case launchFailed
}

public protocol LocalAgentProbeExecuting {
    func execute(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int
    ) throws -> LocalAgentProbeExecutionResult
}

private final class LocalAgentBoundedProbeOutput: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(incoming.prefix(remaining))
        }
        if incoming.count > remaining {
            truncated = true
        }
    }

    func snapshot() -> (String, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    func markTruncated() {
        lock.lock()
        truncated = true
        lock.unlock()
    }
}

private final class LocalAgentProbeProcessWaiter: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var waitStatus: Int32?

    init(processIdentifier: pid_t) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                errno = 0
                result = waitpid(processIdentifier, &status, 0)
            } while result == -1 && errno == EINTR
            lock.lock()
            waitStatus = result == processIdentifier ? status : nil
            lock.unlock()
            group.leave()
        }
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        group.wait(timeout: timeout)
    }

    func exitCode() -> Int32 {
        lock.lock()
        let status = waitStatus
        lock.unlock()
        guard let status, status & 0x7f == 0 else { return -1 }
        return (status >> 8) & 0xff
    }
}

/// Runs fixed argv from the hash-verified catalog. No shell is involved, output
/// is continuously drained and bounded, and a timed-out process group is stopped.
public struct ProcessLocalAgentProbeExecutor: LocalAgentProbeExecuting {
    public init() {}

    public func execute(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int
    ) throws -> LocalAgentProbeExecutionResult {
        guard executablePath.hasPrefix("/"),
              URL(fileURLWithPath: executablePath).standardizedFileURL.path == executablePath
        else {
            throw LocalAgentProbeExecutionError.invalidExecutable
        }

        guard !executablePath.contains("\0"),
              !currentDirectory.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ key, value in
                  !key.isEmpty
                      && !key.contains("=")
                      && !key.contains("\0")
                      && !value.contains("\0")
              })
        else {
            throw LocalAgentProbeExecutionError.launchFailed
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = LocalAgentBoundedProbeOutput(limit: outputLimit)
        let errorOutput = LocalAgentBoundedProbeOutput(limit: outputLimit)
        let readersFinished = DispatchGroup()

        Self.startDraining(outputPipe.fileHandleForReading, into: output, group: readersFinished)
        Self.startDraining(errorPipe.fileHandleForReading, into: errorOutput, group: readersFinished)

        let processIdentifier: pid_t
        do {
            processIdentifier = try Self.spawnIsolated(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                standardOutput: outputPipe.fileHandleForWriting.fileDescriptor,
                standardError: errorPipe.fileHandleForWriting.fileDescriptor,
                outputReadDescriptor: outputPipe.fileHandleForReading.fileDescriptor,
                errorReadDescriptor: errorPipe.fileHandleForReading.fileDescriptor
            )
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = readersFinished.wait(timeout: .now() + 0.2)
            throw LocalAgentProbeExecutionError.launchFailed
        }

        let waiter = LocalAgentProbeProcessWaiter(processIdentifier: processIdentifier)
        let rootTimedOut = waiter.wait(timeout: .now() + max(0.1, timeout)) == .timedOut
        var unsettledProcessTree = false
        if rootTimedOut {
            unsettledProcessTree = true
            Self.stopProcessGroup(processGroupIdentifier: processIdentifier, waiter: waiter)
        } else if Self.processGroupHasLiveMembers(processGroupIdentifier: processIdentifier) {
            // A probe is not successful merely because its root returned zero.
            // Catalog probes must leave no background process or inherited pipe.
            unsettledProcessTree = true
            Self.stopProcessGroup(processGroupIdentifier: processIdentifier, waiter: waiter)
        }

        if readersFinished.wait(timeout: .now() + 0.5) == .timedOut {
            output.markTruncated()
            errorOutput.markTruncated()
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = readersFinished.wait(timeout: .now() + 0.2)
        }
        let (standardOutput, outputWasTruncated) = output.snapshot()
        let (standardError, errorWasTruncated) = errorOutput.snapshot()
        return LocalAgentProbeExecutionResult(
            exitCode: waiter.exitCode(),
            standardOutput: standardOutput,
            standardError: standardError,
            timedOut: unsettledProcessTree,
            outputTruncated: outputWasTruncated || errorWasTruncated
        )
    }

    private static func spawnIsolated(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        standardOutput: Int32,
        standardError: Int32,
        outputReadDescriptor: Int32,
        errorReadDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw LocalAgentProbeExecutionError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard posix_spawn_file_actions_addopen(
            &fileActions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
        ) == 0,
        posix_spawn_file_actions_adddup2(&fileActions, standardOutput, STDOUT_FILENO) == 0,
        posix_spawn_file_actions_adddup2(&fileActions, standardError, STDERR_FILENO) == 0,
        posix_spawn_file_actions_addclose(&fileActions, outputReadDescriptor) == 0,
        posix_spawn_file_actions_addclose(&fileActions, errorReadDescriptor) == 0,
        posix_spawn_file_actions_addclose(&fileActions, standardOutput) == 0,
        posix_spawn_file_actions_addclose(&fileActions, standardError) == 0
        else {
            throw LocalAgentProbeExecutionError.launchFailed
        }
        let chdirResult = currentDirectory.withCString { path in
            if #available(macOS 26, *) {
                posix_spawn_file_actions_addchdir(&fileActions, path)
            } else {
                posix_spawn_file_actions_addchdir_np(&fileActions, path)
            }
        }
        guard chdirResult == 0 else {
            throw LocalAgentProbeExecutionError.launchFailed
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw LocalAgentProbeExecutionError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw LocalAgentProbeExecutionError.launchFailed
        }

        let argv = [executablePath] + arguments
        let env = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let spawnResult = try withCStringVector(argv) { argvPointer in
            try withCStringVector(env) { environmentPointer in
                executablePath.withCString { executablePointer in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argvPointer,
                        environmentPointer
                    )
                }
            }
        }
        guard spawnResult == 0,
              processIdentifier > 0
        else {
            if processIdentifier > 0 {
                _ = kill(processIdentifier, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(processIdentifier, &status, 0)
            }
            throw LocalAgentProbeExecutionError.launchFailed
        }
        return processIdentifier
    }

    private static func withCStringVector<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers = values.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            for case let pointer? in pointers {
                free(pointer)
            }
            throw LocalAgentProbeExecutionError.launchFailed
        }
        pointers.append(nil)
        defer {
            for case let pointer? in pointers {
                free(pointer)
            }
        }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func stopProcessGroup(
        processGroupIdentifier: pid_t,
        waiter: LocalAgentProbeProcessWaiter
    ) {
        _ = kill(-processGroupIdentifier, SIGTERM)
        _ = waiter.wait(timeout: .now() + 0.25)
        if waitForProcessGroupExit(processGroupIdentifier, timeout: 0.25) == false {
            _ = kill(-processGroupIdentifier, SIGKILL)
            _ = waiter.wait(timeout: .now() + 0.4)
            _ = waitForProcessGroupExit(processGroupIdentifier, timeout: 0.4)
        }
    }

    private static func waitForProcessGroupExit(
        _ processGroupIdentifier: pid_t,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if processGroupHasLiveMembers(processGroupIdentifier: processGroupIdentifier) == false {
                return true
            }
            usleep(20_000)
        } while Date() < deadline
        return processGroupHasLiveMembers(processGroupIdentifier: processGroupIdentifier) == false
    }

    private static func processGroupHasLiveMembers(
        processGroupIdentifier: pid_t
    ) -> Bool {
        guard processGroupIdentifier > 0 else { return false }
        var processIdentifiers = [pid_t](repeating: 0, count: 256)
        let byteCount = processIdentifiers.count * MemoryLayout<pid_t>.stride
        let listed = proc_listpgrppids(
            processGroupIdentifier,
            &processIdentifiers,
            Int32(byteCount)
        )
        if listed > 0 {
            let rawCount = Int(listed)
            let count = rawCount <= processIdentifiers.count
                ? rawCount
                : min(rawCount / MemoryLayout<pid_t>.stride, processIdentifiers.count)
            return processIdentifiers.prefix(count).contains { processIdentifier in
                guard processIdentifier > 0 else { return false }
                var info = proc_bsdinfo()
                let result = proc_pidinfo(
                    processIdentifier,
                    PROC_PIDTBSDINFO,
                    0,
                    &info,
                    Int32(MemoryLayout<proc_bsdinfo>.stride)
                )
                return result != MemoryLayout<proc_bsdinfo>.stride
                    || info.pbi_status != UInt32(SZOMB)
            }
        }
        errno = 0
        if kill(-processGroupIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func startDraining(
        _ handle: FileHandle,
        into output: LocalAgentBoundedProbeOutput,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            do {
                while let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty {
                    output.append(chunk)
                }
            } catch {
                // Forced close after the bounded drain deadline is reported as
                // truncation by the caller and therefore cannot pass a probe.
            }
        }
    }
}

public struct LocalAgentDetectionFailure: Equatable, Sendable {
    public let executablePath: String
    public let phase: LocalAgentProbePhase
    public let reasonCode: String

    public init(executablePath: String, phase: LocalAgentProbePhase, reasonCode: String) {
        self.executablePath = executablePath
        self.phase = phase
        self.reasonCode = reasonCode
    }
}

public struct LocalAgentDetectedExecutable: Equatable, Sendable {
    public let catalogID: String
    public let catalogSetRevision: Int
    public let descriptorRevision: Int
    public let rawIdentity: String
    public let displayName: String
    public let executablePath: String
    public let executableIdentityDigest: String
    public let detectedVersion: String
    public let authenticationState: LocalAgentAuthenticationProbeState
    public let authenticationEvidenceRevision: String
    public let cliAuthenticationScopeDigest: String
    public let cliLoginIdentityDigest: String
    public let detectedAt: Date

    public init(
        catalogID: String,
        catalogSetRevision: Int,
        descriptorRevision: Int,
        rawIdentity: String,
        displayName: String,
        executablePath: String,
        executableIdentityDigest: String,
        detectedVersion: String,
        authenticationState: LocalAgentAuthenticationProbeState,
        authenticationEvidenceRevision: String,
        cliAuthenticationScopeDigest: String,
        cliLoginIdentityDigest: String,
        detectedAt: Date
    ) {
        self.catalogID = catalogID
        self.catalogSetRevision = catalogSetRevision
        self.descriptorRevision = descriptorRevision
        self.rawIdentity = rawIdentity
        self.displayName = displayName
        self.executablePath = executablePath
        self.executableIdentityDigest = executableIdentityDigest
        self.detectedVersion = detectedVersion
        self.authenticationState = authenticationState
        self.authenticationEvidenceRevision = authenticationEvidenceRevision
        self.cliAuthenticationScopeDigest = cliAuthenticationScopeDigest
        self.cliLoginIdentityDigest = cliLoginIdentityDigest
        self.detectedAt = detectedAt
    }
}

public struct LocalAgentDetectionReport: Equatable, Sendable {
    public let candidates: [LocalAgentDetectedExecutable]
    public let failures: [LocalAgentDetectionFailure]

    public init(candidates: [LocalAgentDetectedExecutable], failures: [LocalAgentDetectionFailure]) {
        self.candidates = candidates
        self.failures = failures
    }
}

public enum LocalAgentConfigurationDetectionError: Error, Equatable {
    case catalogUnavailable
    case unsupportedCatalogEntry(String)
    case invalidExecutableReference(String)
    case executableChanged(String)
    case missingTerminalPassthroughProfile(String)
}

/// Candidate discovery is read-only. It never writes an executable reference or
/// upgrades a PATH hit into launch authority; saving requires a separate user
/// confirmation through `LocalAgentConfigurationProposalFactory`.
public final class LocalAgentConfigurationDetector {
    private let catalog: RuntimeCatalogProviding
    private let executor: LocalAgentProbeExecuting
    private let environment: () -> [String: String]
    private let homeDirectory: () -> String
    private let isExecutable: (String) -> Bool
    private let executableDigest: (String) -> String?
    private let now: () -> Date
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let maximumCandidates: Int

    public init(
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared,
        executor: LocalAgentProbeExecuting = ProcessLocalAgentProbeExecutor(),
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectory: @escaping () -> String = { NSHomeDirectory() },
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        executableDigest: @escaping (String) -> String? = LocalAgentConfigurationIntegrity.executableDigest(path:),
        now: @escaping () -> Date = Date.init,
        timeout: TimeInterval = 5,
        outputLimit: Int = 4_096,
        maximumCandidates: Int = 16
    ) {
        self.catalog = catalog
        self.executor = executor
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
        self.executableDigest = executableDigest
        self.now = now
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.maximumCandidates = max(1, maximumCandidates)
    }

    public func detect(
        catalogID: String,
        userSelectedExecutablePath: String? = nil
    ) throws -> LocalAgentDetectionReport {
        guard let set = catalog.catalogSet else {
            throw LocalAgentConfigurationDetectionError.catalogUnavailable
        }
        guard let descriptor = set.localAgent(catalogID: catalogID), descriptor.isExecutableCandidate else {
            throw LocalAgentConfigurationDetectionError.unsupportedCatalogEntry(catalogID)
        }
        guard descriptor.executionProfiles.contains(where: {
            $0.kind == .terminalPassthrough && $0.supportLevel != .unsupported
        }) else {
            throw LocalAgentConfigurationDetectionError.missingTerminalPassthroughProfile(catalogID)
        }

        let environment = environment()
        let homeDirectory = homeDirectory()
        var candidates: [LocalAgentDetectedExecutable] = []
        var failures: [LocalAgentDetectionFailure] = []
        let paths = try candidatePaths(
            descriptor: descriptor,
            selectedPath: userSelectedExecutablePath,
            environment: environment,
            homeDirectory: homeDirectory
        )

        for path in paths.prefix(maximumCandidates) {
            guard let digest = executableDigest(path) else {
                failures.append(.init(executablePath: path, phase: .version, reasonCode: "digest_unavailable"))
                continue
            }
            let perCandidateEnvironment = try probeEnvironment(
                descriptor: descriptor,
                executablePath: path,
                environment: environment,
                homeDirectory: homeDirectory
            )
            let versionProbe: LocalAgentProbeExecutionResult
            do {
                versionProbe = try executor.execute(
                    executablePath: path,
                    arguments: descriptor.versionArgv,
                    environment: perCandidateEnvironment,
                    currentDirectory: homeDirectory,
                    timeout: timeout,
                    outputLimit: outputLimit
                )
            } catch {
                failures.append(.init(executablePath: path, phase: .version, reasonCode: "launch_failed"))
                continue
            }
            guard !versionProbe.timedOut else {
                failures.append(.init(executablePath: path, phase: .version, reasonCode: "timeout"))
                continue
            }
            guard versionProbe.exitCode == 0,
                  let detectedVersion = normalizedProbeSummary(versionProbe),
                  !versionProbe.outputTruncated
            else {
                failures.append(.init(
                    executablePath: path,
                    phase: .version,
                    reasonCode: versionProbe.outputTruncated ? "output_truncated" : "probe_failed"
                ))
                continue
            }

            let authentication = authenticationEvidence(
                descriptor: descriptor,
                executablePath: path,
                environment: perCandidateEnvironment,
                homeDirectory: homeDirectory,
                failures: &failures
            )
            guard verifiedRealExecutablePath(path) == path,
                  executableDigest(path) == digest
            else {
                failures.append(.init(
                    executablePath: path,
                    phase: .version,
                    reasonCode: "executable_changed"
                ))
                continue
            }
            let detectedAt = now()
            candidates.append(LocalAgentDetectedExecutable(
                catalogID: descriptor.catalogID,
                catalogSetRevision: set.catalogSetRevision,
                descriptorRevision: descriptor.revision,
                rawIdentity: descriptor.rawIdentity,
                displayName: descriptor.displayName,
                executablePath: path,
                executableIdentityDigest: digest,
                detectedVersion: detectedVersion,
                authenticationState: authentication.state,
                authenticationEvidenceRevision: authentication.revision,
                cliAuthenticationScopeDigest: LocalAgentConfigurationIntegrity.evidenceDigest([
                    descriptor.catalogID, descriptor.rawIdentity, path, "cli-managed-authentication-v1"
                ]),
                cliLoginIdentityDigest: authentication.identityDigest,
                detectedAt: detectedAt
            ))
        }
        return LocalAgentDetectionReport(candidates: candidates, failures: failures)
    }

    private func candidatePaths(
        descriptor: LocalAgentCatalogEntry,
        selectedPath: String?,
        environment: [String: String],
        homeDirectory: String
    ) throws -> [String] {
        if let selectedPath {
            guard let path = verifiedRealExecutablePath(selectedPath) else {
                throw LocalAgentConfigurationDetectionError.invalidExecutableReference(selectedPath)
            }
            return [path]
        }

        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
            .filter(isCanonicalAbsolutePath)
        var unresolved: [String] = []
        for candidate in descriptor.executableCandidates {
            switch candidate.kind {
            case .pathLookup:
                unresolved.append(contentsOf: pathDirectories.map {
                    URL(fileURLWithPath: $0, isDirectory: true)
                        .appendingPathComponent(candidate.value).standardizedFileURL.path
                })
            case .homeRelative:
                unresolved.append(
                    URL(fileURLWithPath: homeDirectory, isDirectory: true)
                        .appendingPathComponent(candidate.value).standardizedFileURL.path
                )
            case .absolute:
                unresolved.append(candidate.value)
            }
        }
        var seen = Set<String>()
        return unresolved.compactMap(verifiedRealExecutablePath).filter { seen.insert($0).inserted }
    }

    private func verifiedRealExecutablePath(_ value: String) -> String? {
        guard isCanonicalAbsolutePath(value), isExecutable(value) else { return nil }
        let resolved = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path
        guard isCanonicalAbsolutePath(resolved), isExecutable(resolved) else { return nil }
        return resolved
    }

    private func isCanonicalAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains(":")
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
            && URL(fileURLWithPath: value).standardizedFileURL.path == value
    }

    private func probeEnvironment(
        descriptor: LocalAgentCatalogEntry,
        executablePath: String,
        environment: [String: String],
        homeDirectory: String
    ) throws -> [String: String] {
        let values = try LocalAgentLaunchEnvironmentBuilder.build(
            executablePath: executablePath,
            rawIdentity: descriptor.rawIdentity,
            pathPolicy: .controlled,
            customPATHEntries: [],
            environmentAllowlist: [],
            descriptor: descriptor,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return Dictionary(uniqueKeysWithValues: values.compactMap { entry in
            guard let separator = entry.firstIndex(of: "=") else { return nil }
            return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
        })
    }

    private func authenticationEvidence(
        descriptor: LocalAgentCatalogEntry,
        executablePath: String,
        environment: [String: String],
        homeDirectory: String,
        failures: inout [LocalAgentDetectionFailure]
    ) -> (state: LocalAgentAuthenticationProbeState, revision: String, identityDigest: String) {
        let revision = "catalog-\(descriptor.revision)-login-status-v1"
        guard let argv = descriptor.loginStatusArgv, !argv.isEmpty else {
            return (
                .unknown,
                revision + "-unavailable",
                LocalAgentConfigurationIntegrity.evidenceDigest([descriptor.catalogID, "authentication-unknown"])
            )
        }
        do {
            let result = try executor.execute(
                executablePath: executablePath,
                arguments: argv,
                environment: environment,
                currentDirectory: homeDirectory,
                timeout: timeout,
                outputLimit: outputLimit
            )
            guard !result.timedOut, !result.outputTruncated else {
                failures.append(.init(
                    executablePath: executablePath,
                    phase: .loginStatus,
                    reasonCode: result.timedOut ? "timeout" : "output_truncated"
                ))
                return (
                    .unknown,
                    revision + "-unknown",
                    LocalAgentConfigurationIntegrity.evidenceDigest([descriptor.catalogID, "authentication-unknown"])
                )
            }
            let summary = normalizedProbeSummary(result) ?? "no-output"
            return (
                result.exitCode == 0 ? .authenticated : .needsLogin,
                revision,
                LocalAgentConfigurationIntegrity.evidenceDigest([
                    descriptor.catalogID, String(result.exitCode), summary
                ])
            )
        } catch {
            failures.append(.init(executablePath: executablePath, phase: .loginStatus, reasonCode: "launch_failed"))
            return (
                .unknown,
                revision + "-unknown",
                LocalAgentConfigurationIntegrity.evidenceDigest([descriptor.catalogID, "authentication-unknown"])
            )
        }
    }

    private func normalizedProbeSummary(_ result: LocalAgentProbeExecutionResult) -> String? {
        let combined = [result.standardOutput, result.standardError]
            .joined(separator: "\n")
            .unicodeScalars
            .map { scalar -> Character in
                CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
            }
        let value = String(combined)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(512))
    }
}

public struct LocalAgentConfigurationDraft: Equatable, Sendable {
    public let configurationID: String
    public let displayName: String
    public let detectedExecutable: LocalAgentDetectedExecutable
    public let executionProfileID: String
    public let selectedProtocol: LocalAgentStructuredProtocol?
    public let workingDirectoryMode: AgentProcessWorkingDirectoryMode
    public let workingDirectoryReference: String?
    public let pathPolicy: LocalAgentPATHPolicy
    public let customPATHEntries: [String]
    public let environmentAllowlist: [String]
    public let explicitlyEnabled: Bool

    public init(
        configurationID: String,
        displayName: String,
        detectedExecutable: LocalAgentDetectedExecutable,
        executionProfileID: String,
        selectedProtocol: LocalAgentStructuredProtocol? = nil,
        workingDirectoryMode: AgentProcessWorkingDirectoryMode = .managedWorkspace,
        workingDirectoryReference: String? = nil,
        pathPolicy: LocalAgentPATHPolicy = .controlled,
        customPATHEntries: [String] = [],
        environmentAllowlist: [String] = [],
        explicitlyEnabled: Bool = false
    ) {
        self.configurationID = configurationID
        self.displayName = displayName
        self.detectedExecutable = detectedExecutable
        self.executionProfileID = executionProfileID
        self.selectedProtocol = selectedProtocol
        self.workingDirectoryMode = workingDirectoryMode
        self.workingDirectoryReference = workingDirectoryReference
        self.pathPolicy = pathPolicy
        self.customPATHEntries = customPATHEntries
        self.environmentAllowlist = environmentAllowlist
        self.explicitlyEnabled = explicitlyEnabled
    }
}

public enum LocalAgentConfigurationProposalFactory {
    public static func makeRecord(
        from draft: LocalAgentConfigurationDraft,
        catalog: RuntimeCatalogProviding = BundledRuntimeCatalog.shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        confirmedAt: Date = Date(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        executableDigest: (String) -> String? = LocalAgentConfigurationIntegrity.executableDigest(path:)
    ) throws -> LocalAgentConfigurationRecord {
        let detected = draft.detectedExecutable
        guard let set = catalog.catalogSet,
              set.catalogSetRevision == detected.catalogSetRevision,
              let descriptor = set.localAgent(catalogID: detected.catalogID),
              descriptor.revision == detected.descriptorRevision,
              descriptor.rawIdentity == detected.rawIdentity
        else {
            throw LocalAgentConfigurationDetectionError.catalogUnavailable
        }
        let standardizedPath = URL(fileURLWithPath: detected.executablePath).standardizedFileURL.path
        let resolvedPath = URL(fileURLWithPath: detected.executablePath)
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard detected.executablePath.hasPrefix("/"),
              standardizedPath == detected.executablePath,
              resolvedPath == detected.executablePath,
              isExecutable(detected.executablePath)
        else {
            throw LocalAgentConfigurationDetectionError.invalidExecutableReference(detected.executablePath)
        }
        guard executableDigest(detected.executablePath) == detected.executableIdentityDigest else {
            throw LocalAgentConfigurationDetectionError.executableChanged(detected.executablePath)
        }
        guard let requestedProfile = descriptor.executionProfiles.first(where: {
            $0.profileID == draft.executionProfileID
                && $0.supportLevel != .unsupported
        }) else {
            throw LocalAgentConfigurationDetectionError.missingTerminalPassthroughProfile(detected.catalogID)
        }
        // The catalog may still contain a retired managed profile so sealed
        // records remain replayable. New or re-verified Claude records must be
        // normalized to the verified PTY profile because stream-json has no
        // tool-result channel in Stacio yet.
        var profile = requestedProfile
        if profile.kind == .managed,
           LocalAgentRuntimeCapabilities.supportsManagedProfile(rawIdentity: detected.rawIdentity) == false {
            guard let terminalProfile = descriptor.executionProfiles.first(where: {
                $0.kind == .terminalPassthrough
                    && $0.supportLevel != .unsupported
            }) else {
                throw LocalAgentConfigurationDetectionError.missingTerminalPassthroughProfile(detected.catalogID)
            }
            profile = terminalProfile
        }
        let selectedProtocol: LocalAgentStructuredProtocol?
        switch profile.kind {
        case .managed:
            selectedProtocol = draft.selectedProtocol ?? descriptor.structuredProtocolPriority.first
            guard let selectedProtocol,
                  descriptor.structuredProtocolPriority.contains(selectedProtocol)
            else {
                throw LocalAgentConfigurationDetectionError.missingTerminalPassthroughProfile(detected.catalogID)
            }
        case .terminalPassthrough, .none:
            selectedProtocol = draft.selectedProtocol
        }

        let provisional = LocalAgentConfigurationRecord(
            configurationID: draft.configurationID,
            catalogID: detected.catalogID,
            catalogSetRevision: detected.catalogSetRevision,
            descriptorRevision: detected.descriptorRevision,
            rawIdentity: detected.rawIdentity,
            userDisplayName: draft.displayName,
            executablePath: detected.executablePath,
            executableIdentityDigest: detected.executableIdentityDigest,
            executableReferenceConfirmedAt: confirmedAt,
            detectedVersion: detected.detectedVersion,
            authenticationState: detected.authenticationState,
            selectedProtocol: selectedProtocol,
            executionProfileID: profile.profileID,
            executionProfileRevision: profile.revision,
            authenticationEvidenceRevision: detected.authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: detected.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: detected.cliLoginIdentityDigest,
            workingDirectoryMode: draft.workingDirectoryMode,
            workingDirectoryReference: draft.workingDirectoryReference,
            pathPolicy: draft.pathPolicy,
            customPATHEntries: draft.customPATHEntries,
            environmentAllowlist: draft.environmentAllowlist,
            environmentDigest: "pending",
            lastVerifiedAt: confirmedAt,
            explicitlyEnabled: draft.explicitlyEnabled
        )
        let launchEnvironment = try LocalAgentLaunchEnvironmentBuilder.build(
            record: provisional,
            descriptor: descriptor,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return LocalAgentConfigurationRecord(
            configurationID: provisional.configurationID,
            catalogID: provisional.catalogID,
            catalogSetRevision: provisional.catalogSetRevision,
            descriptorRevision: provisional.descriptorRevision,
            rawIdentity: provisional.rawIdentity,
            userDisplayName: provisional.userDisplayName,
            executablePath: provisional.executablePath,
            executableIdentityDigest: provisional.executableIdentityDigest,
            executableReferenceConfirmedAt: provisional.executableReferenceConfirmedAt,
            detectedVersion: provisional.detectedVersion,
            authenticationState: provisional.authenticationState,
            selectedProtocol: provisional.selectedProtocol,
            executionProfileID: provisional.executionProfileID,
            executionProfileRevision: provisional.executionProfileRevision,
            authenticationEvidenceRevision: provisional.authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: provisional.cliAuthenticationScopeDigest,
            cliLoginIdentityDigest: provisional.cliLoginIdentityDigest,
            workingDirectoryMode: provisional.workingDirectoryMode,
            workingDirectoryReference: provisional.workingDirectoryReference,
            pathPolicy: provisional.pathPolicy,
            customPATHEntries: provisional.customPATHEntries,
            environmentAllowlist: provisional.environmentAllowlist,
            environmentDigest: LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment),
            lastVerifiedAt: provisional.lastVerifiedAt,
            explicitlyEnabled: provisional.explicitlyEnabled
        )
    }
}
