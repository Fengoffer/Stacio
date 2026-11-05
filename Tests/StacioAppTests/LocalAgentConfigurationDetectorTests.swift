import Darwin
import Foundation
import XCTest
@testable import StacioApp

final class LocalAgentConfigurationDetectorTests: XCTestCase {
    func testDetectionUsesCatalogArgvMinimalEnvironmentAndResolvedExecutable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let executor = RecordingProbeExecutor(results: [
            .init(exitCode: 0, standardOutput: "codex-cli 1.2.3\n", standardError: ""),
            .init(exitCode: 0, standardOutput: "Logged in as person@example.com\n", standardError: "")
        ])
        let detector = makeDetector(fixture: fixture, executor: executor)

        let report = try detector.detect(catalogID: "local-agent.codex")

        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(candidate.executablePath, fixture.realExecutableURL.path)
        XCTAssertEqual(candidate.detectedVersion, "codex-cli 1.2.3")
        XCTAssertEqual(candidate.authenticationState, .authenticated)
        XCTAssertTrue(candidate.cliLoginIdentityDigest.hasPrefix("sha256:"))
        XCTAssertFalse(candidate.cliLoginIdentityDigest.contains("person@example.com"))
        XCTAssertEqual(executor.requests.map(\.arguments), [["--version"], ["login", "status"]])
        XCTAssertTrue(executor.requests.allSatisfy { $0.executablePath == fixture.realExecutableURL.path })
        XCTAssertTrue(executor.requests.allSatisfy { $0.environment["ACCESS_TOKEN"] == nil })
        XCTAssertTrue(executor.requests.allSatisfy { $0.environment["HOME"] == fixture.root.path })
        XCTAssertTrue(executor.requests.allSatisfy { $0.currentDirectory == fixture.root.path })
    }

    func testNonzeroLoginProbeProducesNeedsLoginWithoutPersistingOutput() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let executor = RecordingProbeExecutor(results: [
            .init(exitCode: 0, standardOutput: "codex 2.0", standardError: ""),
            .init(exitCode: 1, standardOutput: "", standardError: "Not logged in")
        ])

        let candidate = try XCTUnwrap(
            makeDetector(fixture: fixture, executor: executor)
                .detect(catalogID: "local-agent.codex").candidates.first
        )

        XCTAssertEqual(candidate.authenticationState, .needsLogin)
        XCTAssertFalse(candidate.cliLoginIdentityDigest.contains("Not logged in"))
    }

    func testMissingLoginStatusArgvProducesExplicitUnknownEvidence() throws {
        let fixture = try makeFixture(executableName: "claude")
        defer { fixture.cleanup() }
        let executor = RecordingProbeExecutor(results: [
            .init(exitCode: 0, standardOutput: "claude 1.0", standardError: "")
        ])

        let candidate = try XCTUnwrap(
            makeDetector(fixture: fixture, executor: executor)
                .detect(catalogID: "local-agent.claude-code").candidates.first
        )

        XCTAssertEqual(candidate.authenticationState, .unknown)
        XCTAssertTrue(candidate.authenticationEvidenceRevision.hasSuffix("-unavailable"))
        XCTAssertEqual(executor.requests.count, 1)
    }

    func testTimedOutOrTruncatedVersionProbeNeverBecomesCandidate() throws {
        for result in [
            LocalAgentProbeExecutionResult(
                exitCode: -1, standardOutput: "", standardError: "", timedOut: true
            ),
            LocalAgentProbeExecutionResult(
                exitCode: 0,
                standardOutput: "partial",
                standardError: "",
                outputTruncated: true
            )
        ] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let report = try makeDetector(
                fixture: fixture,
                executor: RecordingProbeExecutor(results: [result])
            ).detect(catalogID: "local-agent.codex")
            XCTAssertTrue(report.candidates.isEmpty)
            XCTAssertEqual(report.failures.count, 1)
        }
    }

    func testUserSelectedExecutableMustBeCanonicalAndExecutable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let detector = makeDetector(
            fixture: fixture,
            executor: RecordingProbeExecutor(results: [])
        )

        XCTAssertThrowsError(try detector.detect(
            catalogID: "local-agent.codex",
            userSelectedExecutablePath: fixture.root.appendingPathComponent("missing/../codex").path
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentConfigurationDetectionError,
                .invalidExecutableReference(fixture.root.appendingPathComponent("missing/../codex").path)
            )
        }
    }

    func testExecutableReplacementDuringProbeNeverBecomesCandidate() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let executor = RecordingProbeExecutor(
            results: [
                .init(exitCode: 0, standardOutput: "codex 1.0", standardError: ""),
                .init(exitCode: 0, standardOutput: "authenticated", standardError: "")
            ],
            afterExecution: { requestIndex in
                guard requestIndex == 0 else { return }
                try? Data("#!/bin/sh\necho replaced\n".utf8)
                    .write(to: fixture.realExecutableURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))],
                    ofItemAtPath: fixture.realExecutableURL.path
                )
            }
        )

        let report = try makeDetector(fixture: fixture, executor: executor)
            .detect(catalogID: "local-agent.codex")

        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertEqual(report.failures.last?.reasonCode, "executable_changed")
    }

    func testProposalUsesCatalogProfileAndFrozenEnvironmentEvidence() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let executor = RecordingProbeExecutor(results: [
            .init(exitCode: 0, standardOutput: "codex 3.0", standardError: ""),
            .init(exitCode: 0, standardOutput: "authenticated", standardError: "")
        ])
        let candidate = try XCTUnwrap(
            makeDetector(fixture: fixture, executor: executor)
                .detect(catalogID: "local-agent.codex").candidates.first
        )
        let confirmedAt = Date(timeIntervalSince1970: 1_786_000_100)

        let record = try LocalAgentConfigurationProposalFactory.makeRecord(
            from: LocalAgentConfigurationDraft(
                configurationID: "local-agent-config",
                displayName: "Work Codex",
                detectedExecutable: candidate,
                executionProfileID: "terminal-passthrough",
                explicitlyEnabled: true
            ),
            environment: fixture.environment,
            homeDirectory: fixture.root.path,
            confirmedAt: confirmedAt
        )

        XCTAssertEqual(record.executionProfileID, "terminal-passthrough")
        XCTAssertEqual(record.executionProfileRevision, 1)
        XCTAssertEqual(record.executableReferenceConfirmedAt, confirmedAt)
        XCTAssertEqual(record.lastVerifiedAt, confirmedAt)
        XCTAssertTrue(record.environmentDigest.hasPrefix("sha256:"))
        XCTAssertEqual(record.catalogSetRevision, 3)
        XCTAssertEqual(record.descriptorRevision, 3)
    }

    func testProposalRejectsExecutableReplacedAfterDetection() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let executor = RecordingProbeExecutor(results: [
            .init(exitCode: 0, standardOutput: "codex 3.0", standardError: ""),
            .init(exitCode: 0, standardOutput: "authenticated", standardError: "")
        ])
        let candidate = try XCTUnwrap(
            makeDetector(fixture: fixture, executor: executor)
                .detect(catalogID: "local-agent.codex").candidates.first
        )
        try Data("#!/bin/sh\necho replaced\n".utf8)
            .write(to: fixture.realExecutableURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: fixture.realExecutableURL.path
        )

        XCTAssertThrowsError(try LocalAgentConfigurationProposalFactory.makeRecord(
            from: LocalAgentConfigurationDraft(
                configurationID: "local-agent-config",
                displayName: "Work Codex",
                detectedExecutable: candidate,
                executionProfileID: "terminal-passthrough"
            ),
            environment: fixture.environment,
            homeDirectory: fixture.root.path
        )) { error in
            XCTAssertEqual(
                error as? LocalAgentConfigurationDetectionError,
                .executableChanged(fixture.realExecutableURL.path)
            )
        }
    }

    func testProcessProbeExecutorBoundsOutputAndTimesOut() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-process-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let noisy = root.appendingPathComponent("noisy")
        let spinning = root.appendingPathComponent("spinning")
        try writeExecutable("#!/bin/sh\nprintf '%*s' 12000 '' | tr ' ' x\n", to: noisy)
        try writeExecutable("#!/bin/sh\nwhile :; do :; done\n", to: spinning)
        let executor = ProcessLocalAgentProbeExecutor()

        let bounded = try executor.execute(
            executablePath: noisy.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: root.path,
            timeout: 2,
            outputLimit: 128
        )
        XCTAssertTrue(bounded.outputTruncated)
        XCTAssertLessThanOrEqual(bounded.standardOutput.utf8.count, 128)

        let timedOut = try executor.execute(
            executablePath: spinning.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: root.path,
            timeout: 0.1,
            outputLimit: 128
        )
        XCTAssertTrue(timedOut.timedOut)
    }

    func testProcessProbeExecutorCapturesTailFromShortLivedProcess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-process-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("short-lived")
        try writeExecutable("#!/bin/sh\nprintf tail-without-newline\n", to: executable)

        let result = try ProcessLocalAgentProbeExecutor().execute(
            executablePath: executable.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: root.path,
            timeout: 2,
            outputLimit: 128
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "tail-without-newline")
        XCTAssertFalse(result.outputTruncated)
    }

    func testProcessProbeExecutorTerminatesDescendantProcessGroup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-process-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("with-descendant")
        let childPIDURL = root.appendingPathComponent("child.pid")
        try writeExecutable(
            "#!/bin/sh\n(trap '' TERM; while :; do sleep 1; done) &\nprintf '%s' \"$!\" > \"$1\"\nwhile :; do sleep 1; done\n",
            to: executable
        )

        let result = try ProcessLocalAgentProbeExecutor().execute(
            executablePath: executable.path,
            arguments: [childPIDURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: root.path,
            timeout: 0.75,
            outputLimit: 128
        )
        XCTAssertTrue(result.timedOut)

        guard let childPIDText = try? String(contentsOf: childPIDURL, encoding: .utf8),
              let childPID = Int32(childPIDText)
        else {
            return XCTFail("Descendant PID was not captured: \(result.standardError)")
        }
        defer { _ = kill(childPID, SIGKILL) }
        let deadline = Date().addingTimeInterval(1)
        while kill(childPID, 0) == 0, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testProcessProbeExecutorRejectsSuccessfulRootExitWhileDescendantLives() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-process-orphan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("leaves-descendant")
        let childPIDURL = root.appendingPathComponent("child.pid")
        try writeExecutable(
            "#!/bin/sh\n(trap '' TERM HUP; while :; do sleep 1; done) &\nprintf '%s' \"$!\" > \"$1\"\nexit 0\n",
            to: executable
        )

        let result = try ProcessLocalAgentProbeExecutor().execute(
            executablePath: executable.path,
            arguments: [childPIDURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: root.path,
            timeout: 2,
            outputLimit: 128
        )

        guard let childPIDText = try? String(contentsOf: childPIDURL, encoding: .utf8),
              let childPID = Int32(childPIDText)
        else {
            return XCTFail("Descendant PID was not captured: \(result.standardError)")
        }
        defer { _ = kill(childPID, SIGKILL) }
        XCTAssertTrue(
            result.timedOut,
            "A successful root exit is not a successful probe while its process group is still live"
        )
        let deadline = Date().addingTimeInterval(1)
        while kill(childPID, 0) == 0, Date() < deadline {
            usleep(20_000)
        }
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    private func makeDetector(
        fixture: DetectorFixture,
        executor: LocalAgentProbeExecuting
    ) -> LocalAgentConfigurationDetector {
        LocalAgentConfigurationDetector(
            executor: executor,
            environment: { fixture.environment },
            homeDirectory: { fixture.root.path },
            now: { Date(timeIntervalSince1970: 1_786_000_000) },
            timeout: 0.5,
            outputLimit: 1_024
        )
    }

    private func makeFixture(executableName: String = "codex") throws -> DetectorFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-agent-detector-\(UUID().uuidString)", isDirectory: true)
        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let pathDirectory = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        let realExecutable = realDirectory.appendingPathComponent(executableName)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: realExecutable)
        try FileManager.default.createSymbolicLink(
            at: pathDirectory.appendingPathComponent(executableName),
            withDestinationURL: realExecutable
        )
        return DetectorFixture(
            root: root,
            realExecutableURL: realExecutable,
            environment: [
                "HOME": root.path,
                "PATH": pathDirectory.path,
                "LANG": "zh_CN.UTF-8",
                "TERM": "xterm-256color",
                "TMPDIR": root.path,
                "ACCESS_TOKEN": "must-not-pass"
            ]
        )
    }

    private func writeExecutable(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }
}

private struct DetectorFixture {
    let root: URL
    let realExecutableURL: URL
    let environment: [String: String]

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingProbeExecutor: LocalAgentProbeExecuting {
    struct Request {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
        let currentDirectory: String
        let timeout: TimeInterval
        let outputLimit: Int
    }

    private var results: [LocalAgentProbeExecutionResult]
    private let afterExecution: ((Int) -> Void)?
    private(set) var requests: [Request] = []

    init(
        results: [LocalAgentProbeExecutionResult],
        afterExecution: ((Int) -> Void)? = nil
    ) {
        self.results = results
        self.afterExecution = afterExecution
    }

    func execute(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String,
        timeout: TimeInterval,
        outputLimit: Int
    ) throws -> LocalAgentProbeExecutionResult {
        requests.append(Request(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            timeout: timeout,
            outputLimit: outputLimit
        ))
        guard !results.isEmpty else { throw LocalAgentProbeExecutionError.launchFailed }
        let result = results.removeFirst()
        afterExecution?(requests.count - 1)
        return result
    }
}
