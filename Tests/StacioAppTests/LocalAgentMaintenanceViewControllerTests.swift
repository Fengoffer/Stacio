import AppKit
import Foundation
import SwiftTerm
import XCTest
@testable import StacioApp

final class LocalAgentMaintenanceViewControllerTests: XCTestCase {
    func testStartUsesFrozenRequestAndRegistersManagedIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launcher = RecordingMaintenanceLauncher()
        var registeredIdentity: LocalAgentMaintenanceProcessIdentity?
        let controller = LocalAgentMaintenanceViewController(
            request: fixture.request,
            processLauncher: launcher,
            onProcessStarted: {
                registeredIdentity = $0
                return true
            }
        )

        XCTAssertTrue(controller.start())

        XCTAssertEqual(controller.state, .running)
        XCTAssertEqual(registeredIdentity, launcher.identity)
        XCTAssertEqual(launcher.executable, fixture.request.executablePath)
        XCTAssertEqual(launcher.arguments, fixture.request.arguments)
        XCTAssertEqual(launcher.environment, fixture.request.environment)
        XCTAssertEqual(launcher.currentDirectory, fixture.request.currentDirectory)
        XCTAssertEqual(launcher.startCount, 1)
    }

    func testMissingIdentityTerminatesTreeAndDoesNotReportOrdinaryFailure() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launcher = RecordingMaintenanceLauncher()
        launcher.identity = nil
        launcher.terminateStopsImmediately = false
        let controller = LocalAgentMaintenanceViewController(
            request: fixture.request,
            processLauncher: launcher,
            onProcessStarted: { _ in
                XCTFail("An unverified process identity must not be journaled")
                return true
            }
        )
        var outcome: LocalAgentMaintenanceLaunchOutcome?
        controller.onCompletion = { outcome = $0 }

        XCTAssertFalse(controller.start())
        XCTAssertEqual(launcher.terminateCount, 1)
        XCTAssertNil(outcome, "Completion must wait for the complete process tree to exit")

        launcher.running = false
        controller.processTerminated(source: controller.terminalView, exitCode: nil)
        XCTAssertEqual(outcome, .stateUnknown(referenceID: fixture.request.operationID))
        XCTAssertEqual(controller.state, .finished)
    }

    func testRejectedJournalRegistrationWaitsForTreeExitAndFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launcher = RecordingMaintenanceLauncher()
        launcher.terminateStopsImmediately = false
        let controller = LocalAgentMaintenanceViewController(
            request: fixture.request,
            processLauncher: launcher,
            onProcessStarted: { _ in false }
        )
        var outcome: LocalAgentMaintenanceLaunchOutcome?
        controller.onCompletion = { outcome = $0 }

        XCTAssertFalse(controller.start())
        XCTAssertEqual(launcher.terminateCount, 1)
        XCTAssertNil(outcome)

        launcher.running = false
        controller.processTerminated(source: controller.terminalView, exitCode: 0)
        XCTAssertEqual(outcome, .stateUnknown(referenceID: fixture.request.operationID))
    }

    func testStopSendsInterruptBeforeExplicitForceStop() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launcher = RecordingMaintenanceLauncher()
        launcher.terminateStopsImmediately = true
        let controller = LocalAgentMaintenanceViewController(
            request: fixture.request,
            processLauncher: launcher,
            forceStopGraceInterval: 0.01,
            onProcessStarted: { _ in true }
        )
        var outcome: LocalAgentMaintenanceLaunchOutcome?
        controller.onCompletion = { outcome = $0 }
        XCTAssertTrue(controller.start())

        controller.requestStop()
        XCTAssertEqual(launcher.interruptCount, 1)
        XCTAssertEqual(launcher.terminateCount, 0)
        XCTAssertEqual(controller.state, .interrupting)

        let deadline = Date().addingTimeInterval(0.5)
        while controller.state == .interrupting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.state, .forceStopAvailable)

        controller.requestStop()
        XCTAssertEqual(launcher.terminateCount, 1)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(controller.state, .finished)
    }

    func testNaturalExitWithoutExitCodeRequiresReconciliation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launcher = RecordingMaintenanceLauncher()
        let controller = LocalAgentMaintenanceViewController(
            request: fixture.request,
            processLauncher: launcher,
            onProcessStarted: { _ in true }
        )
        var outcome: LocalAgentMaintenanceLaunchOutcome?
        controller.onCompletion = { outcome = $0 }
        XCTAssertTrue(controller.start())

        launcher.running = false
        controller.processTerminated(source: controller.terminalView, exitCode: nil)

        XCTAssertEqual(outcome, .stateUnknown(referenceID: fixture.request.operationID))
    }
}

private final class RecordingMaintenanceLauncher: LocalTerminalProcessLaunching {
    var running = false
    var terminateStopsImmediately = true
    var identity: LocalAgentMaintenanceProcessIdentity? = .init(
        processIdentifier: 7_101,
        processGroupIdentifier: 7_101,
        trustedStartTime: Date(timeIntervalSince1970: 1_786_450_000)
    )
    private(set) var executable: String?
    private(set) var arguments: [String]?
    private(set) var environment: [String]?
    private(set) var currentDirectory: String?
    private(set) var startCount = 0
    private(set) var terminateCount = 0
    private(set) var interruptCount = 0

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool { running }

    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        startCount += 1
        self.executable = executable
        arguments = args
        self.environment = environment
        self.currentDirectory = currentDirectory
        running = true
    }

    func terminate(_ terminalView: LocalProcessTerminalView) {
        terminateCount += 1
        if terminateStopsImmediately {
            running = false
        }
    }

    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {}

    func managedProcessGroupID(_ terminalView: LocalProcessTerminalView) -> Int32? {
        identity?.processGroupIdentifier
    }

    func managedProcessIdentifier(_ terminalView: LocalProcessTerminalView) -> Int32? {
        identity?.processIdentifier
    }

    func managedProcessTrustedStartTime(_ terminalView: LocalProcessTerminalView) -> Date? {
        identity?.trustedStartTime
    }

    func interrupt(_ terminalView: LocalProcessTerminalView) {
        interruptCount += 1
    }
}

private struct Fixture {
    let root: URL
    let executable: URL
    let request: LocalAgentMaintenanceLaunchRequest

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maintenance-view-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("agent")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        request = LocalAgentMaintenanceLaunchRequest(
            operationID: "maintenance-view-test",
            configurationID: "local-agent-test",
            action: .login,
            displayName: "Test Agent",
            executablePath: executable.path,
            executableIdentityDigest: "sha256:" + String(repeating: "a", count: 64),
            arguments: ["login", "--device"],
            environment: ["HOME=\(root.path)", "PATH=/usr/bin:/bin"],
            currentDirectory: root.path
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
