import AppKit
import StacioAgentBridge
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class AgentExecutionCoordinatorTests: XCTestCase {
    private let fastVisibleCompletion = AgentVisibleTerminalCompletion(
        idleInterval: 0.02,
        maximumDuration: 0.05
    )

    private func makeVisibleCoordinator(
        target: AgentTerminalTarget,
        authorizer: AgentActionAuthorizing,
        auditRecorder: AgentActionAuditRecording? = nil,
        sessionLister: AgentTerminalSessionListing? = nil,
        executionModeResolver: (() -> AgentExecutionMode)? = nil,
        capabilityRegistry: LocalAgentCapabilityRegistry = .shared
    ) -> AgentExecutionCoordinator {
        AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: target),
            authorizer: authorizer,
            auditRecorder: auditRecorder,
            sessionLister: sessionLister,
            executionModeResolver: executionModeResolver,
            visibleTerminalCompletion: fastVisibleCompletion,
            localAgentCapabilityRegistry: capabilityRegistry
        )
    }

    func testManagedCapabilityRejectsCommandOutsideBoundRuntime() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-other",
            agentTitle: "other"
        )
        let registry = LocalAgentCapabilityRegistry()
        registry.register(
            capabilityID: "scope-bound",
            targetRuntimeGenerations: ["term-bound": 0],
            processGeneration: 1
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: AllowingAgentActionAuthorizer(),
            capabilityRegistry: registry
        )
        let request = AgentBridgeRequest(
            id: "req-outside-scope",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term-other"),
                    command: "uptime",
                    follow: true
                )
            ),
            capabilityID: "scope-bound"
        )

        XCTAssertThrowsError(try coordinator.runCommand(request)) { error in
            XCTAssertEqual(error as? AgentExecutionError, .capabilityRejected)
        }
        XCTAssertTrue(terminal.sentInput.isEmpty)
    }

    func testManagedCapabilityRejectsSameRuntimeAfterReconnect() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-bound",
            agentTitle: "reconnected",
            runtimeGeneration: 8
        )
        let registry = LocalAgentCapabilityRegistry()
        registry.register(
            capabilityID: "scope-old-lease",
            targetRuntimeGenerations: ["term-bound": 7],
            processGeneration: 1
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: AllowingAgentActionAuthorizer(),
            capabilityRegistry: registry
        )
        let request = AgentBridgeRequest(
            id: "req-old-lease",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term-bound"),
                    command: "uptime",
                    follow: true
                )
            ),
            capabilityID: "scope-old-lease"
        )

        XCTAssertThrowsError(try coordinator.runCommand(request)) { error in
            XCTAssertEqual(error as? AgentExecutionError, .capabilityRejected)
        }
        XCTAssertTrue(terminal.sentInput.isEmpty)
    }

    func testVisibleCommandRejectsSameRuntimeAfterReconnectDuringApproval() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-reused",
            agentTitle: "deploy@prod",
            runtimeGeneration: 1
        )
        terminal.onTrace = { event in
            if event.state == .approved {
                terminal.runtimeGeneration = 2
            }
        }
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore
        )
        let request = AgentBridgeRequest(
            id: "req-stale-visible-lease",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID("term-reused"),
                command: "uptime",
                follow: true,
                expectedRuntimeGeneration: 1
            ))
        )

        XCTAssertThrowsError(try coordinator.runCommand(request)) { error in
            XCTAssertEqual(error as? AgentExecutionError, .terminalRuntimeLeaseChanged)
        }
        XCTAssertTrue(terminal.sentInput.isEmpty)
        XCTAssertFalse(terminal.interactionLocked)
        XCTAssertEqual(auditStore.events.map(\.state), ["failed"])
        XCTAssertEqual(terminal.traceEventsForTesting.last?.state, .failed)
        XCTAssertEqual(
            terminal.traceEventsForTesting.last?.metadata?["expectedRuntimeGeneration"],
            "1"
        )
        XCTAssertEqual(
            terminal.traceEventsForTesting.last?.metadata?["actualRuntimeGeneration"],
            "2"
        )
    }

    func testVisibleCommandRejectsCapabilityRevokedAfterApprovalBeforeWrite() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = LocalAgentCapabilityProcessIdentity(
            processIdentifier: 700,
            processGroupIdentifier: 700,
            trustedStartTime: now
        )
        let registry = LocalAgentCapabilityRegistry { processID in
            processID == identity.processIdentifier ? identity : nil
        }
        XCTAssertTrue(registry.register(
            capabilityID: "scope-revoked-after-approval",
            targetRuntimeGenerations: ["term-capability": 4],
            processGeneration: 1,
            processGroupID: identity.processGroupIdentifier,
            processIdentifier: identity.processIdentifier,
            trustedStartTime: identity.trustedStartTime,
            expiresAt: Date.distantFuture
        ))
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-capability",
            agentTitle: "deploy@prod",
            runtimeGeneration: 4
        )
        terminal.onTrace = { event in
            if event.state == .approved {
                registry.revoke(capabilityID: "scope-revoked-after-approval")
            }
        }
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            capabilityRegistry: registry
        )

        XCTAssertThrowsError(try coordinator.runCommand(AgentBridgeRequest(
            id: "req-revoked-after-approval",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 700),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(terminal.runtimeID),
                command: "uptime",
                follow: true,
                expectedRuntimeGeneration: 4
            )),
            capabilityID: "scope-revoked-after-approval"
        ))) { error in
            XCTAssertEqual(error as? AgentExecutionError, .capabilityRejected)
        }

        XCTAssertTrue(terminal.sentInput.isEmpty)
        XCTAssertFalse(terminal.interactionLocked)
        XCTAssertEqual(terminal.traceEventsForTesting.last?.state, .failed)
        XCTAssertEqual(
            terminal.traceEventsForTesting.last?.metadata?["authorityState"],
            "revokedExpiredOrProcessExited"
        )
    }

    func testVisibleCommandRejectsReplacementPaneWithSameRuntimeLease() throws {
        let original = RecordingAgentTerminalTarget(
            runtimeID: "term-replaced",
            agentTitle: "original",
            runtimeGeneration: 11
        )
        let replacement = RecordingAgentTerminalTarget(
            runtimeID: "term-replaced",
            agentTitle: "replacement",
            runtimeGeneration: 11
        )
        let resolver = MutableAgentTerminalResolver(target: original)
        original.onTrace = { event in
            if event.state == .approved {
                resolver.target = replacement
            }
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: resolver,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            visibleTerminalCompletion: fastVisibleCompletion
        )

        XCTAssertThrowsError(try coordinator.runCommand(AgentBridgeRequest(
            id: "req-replaced-pane",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(original.runtimeID),
                command: "uptime",
                follow: true,
                expectedRuntimeGeneration: 11
            ))
        ))) { error in
            XCTAssertEqual(error as? AgentExecutionError, .terminalRuntimeLeaseChanged)
        }

        XCTAssertTrue(original.sentInput.isEmpty)
        XCTAssertTrue(replacement.sentInput.isEmpty)
        XCTAssertFalse(original.interactionLocked)
        XCTAssertEqual(original.traceEventsForTesting.last?.state, .failed)
    }

    func testVisibleObservationRejectsOutputFromReconnectedSameRuntime() throws {
        let outputHub = TerminalOutputBroadcastHub()
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-observation-reused",
            agentTitle: "deploy@prod",
            runtimeGeneration: 21
        )
        terminal.onTrace = { event in
            if event.state == .running {
                terminal.runtimeGeneration = 22
                outputHub.publishOutput(
                    runtimeID: terminal.runtimeID,
                    bytes: Array("stale-output-from-new-connection\nroot@host:~# ".utf8)
                )
            }
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            visibleTerminalOutputHub: outputHub,
            visibleTerminalCompletion: fastVisibleCompletion
        )

        XCTAssertThrowsError(try coordinator.runCommand(AgentBridgeRequest(
            id: "req-observation-reused",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(terminal.runtimeID),
                command: "uptime",
                follow: true,
                expectedRuntimeGeneration: 21
            ))
        ))) { error in
            XCTAssertEqual(error as? AgentExecutionError, .terminalRuntimeLeaseChanged)
        }

        XCTAssertEqual(terminal.sentInput, ["uptime\n"])
        XCTAssertFalse(terminal.interactionLocked)
        XCTAssertFalse(terminal.traceEventsForTesting.contains { event in
            event.metadata?["terminalOutputSummary"]?.contains("stale-output") == true
        })
        XCTAssertEqual(terminal.traceEventsForTesting.last?.state, .failed)
    }

    func testVisibleTerminalRejectsReentrantSecondWriter() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-single-writer",
            agentTitle: "local"
        )
        var coordinator: AgentExecutionCoordinator!
        var nestedError: AgentExecutionError?
        var attemptedNestedWrite = false
        terminal.onTrace = { event in
            guard event.state == .queued, attemptedNestedWrite == false else { return }
            attemptedNestedWrite = true
            do {
                _ = try coordinator.runCommand(AgentBridgeRequest(
                    id: "req-second-writer",
                    actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                    action: .runCommand(AgentRunCommandRequest(
                        target: .runtimeID(terminal.runtimeID),
                        command: "echo second",
                        follow: true
                    ))
                ))
            } catch {
                nestedError = error as? AgentExecutionError
            }
        }
        coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer()
        )

        _ = try coordinator.runCommand(AgentBridgeRequest(
            id: "req-first-writer",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(terminal.runtimeID),
                command: "tail -f /tmp/stacio.log",
                follow: true
            ))
        ))

        XCTAssertEqual(nestedError, .requestAlreadyActive)
        XCTAssertEqual(terminal.sentInput, ["tail -f /tmp/stacio.log\n"])
        XCTAssertTrue(terminal.interactionLocked)
        _ = coordinator.takeOverTask(requestID: "req-first-writer")
        XCTAssertFalse(terminal.interactionLocked)
    }

    func testBackgroundTakeoverDoesNotUnlockConcurrentVisibleWriter() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-mixed-modes",
            agentTitle: "deploy@prod",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let runner = RecordingAgentBackgroundCommandRunner()
        var mode = AgentExecutionMode.visibleTerminal
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionModeResolver: { mode },
            backgroundCommandRunner: runner,
            visibleTerminalCompletion: fastVisibleCompletion
        )
        _ = try coordinator.runCommand(AgentBridgeRequest(
            id: "req-visible-owner",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(terminal.runtimeID),
                command: "tail -f /tmp/stacio.log",
                follow: true
            ))
        ))
        XCTAssertTrue(terminal.interactionLocked)

        mode = .backgroundTask
        _ = try coordinator.runCommand(AgentBridgeRequest(
            id: "req-background-owner",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(terminal.runtimeID),
                command: "uptime",
                follow: true
            ))
        ))
        XCTAssertEqual(
            coordinator.takeOverTask(requestID: "req-background-owner")?.state,
            .takenOver
        )
        XCTAssertTrue(
            terminal.interactionLocked,
            "A background-task control must not release the visible writer's terminal lock"
        )

        _ = coordinator.takeOverTask(requestID: "req-visible-owner")
        XCTAssertFalse(terminal.interactionLocked)
    }

    func testCompletedBackgroundRequestIDReplayDoesNotRunCommandAgain() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-completed-replay",
            agentTitle: "remote",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let runner = RecordingAgentBackgroundCommandRunner()
        runner.eventsToEmit = [
            AgentTraceEvent(
                requestID: "req-completed-replay",
                state: .completed,
                message: "已完成",
                redactedCommand: "pwd",
                metadata: ["terminalOutputSummary": "ok"]
            )
        ]
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: runner
        )
        let request = AgentBridgeRequest(
            id: "req-completed-replay",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 42),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(terminal.runtimeID),
                command: "pwd",
                follow: true
            ))
        )

        _ = try coordinator.runCommand(request)
        let replay = try coordinator.runCommand(request)
        XCTAssertEqual(runner.commands, ["pwd"], "完成后的网络重试不得再次启动命令")
        XCTAssertEqual(replay.map(\.state), [.completed])

        let changedRequest = AgentBridgeRequest(
            id: request.id,
            actor: request.actor,
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID(terminal.runtimeID),
                command: "rm -rf /tmp/other",
                follow: true
            ))
        )
        XCTAssertThrowsError(try coordinator.runCommand(changedRequest)) { error in
            XCTAssertEqual(error as? AgentExecutionError, .requestAlreadyActive)
        }
        XCTAssertEqual(runner.commands, ["pwd"])
    }

    func testLegacyVisibleCommandWithoutGenerationFreezesIngressLeaseAcrossApproval() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-reused",
            agentTitle: "deploy@prod",
            runtimeGeneration: 21
        )
        terminal.onTrace = { event in
            if event.state == .approved {
                terminal.runtimeGeneration = 22
            }
        }
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore
        )
        let request = AgentBridgeRequest(
            id: "req-legacy-stale-visible-lease",
            actor: AgentActor(kind: .externalCLI, name: "legacy-agent", processID: 100),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID("term-reused"),
                command: "uptime",
                follow: true
            ))
        )

        XCTAssertThrowsError(try coordinator.runCommand(request)) { error in
            XCTAssertEqual(error as? AgentExecutionError, .terminalRuntimeLeaseChanged)
        }
        XCTAssertTrue(terminal.sentInput.isEmpty)
        XCTAssertEqual(auditStore.events.map(\.state), ["failed"])
        XCTAssertEqual(
            terminal.traceEventsForTesting.last?.metadata?["expectedRuntimeGeneration"],
            "21"
        )
        XCTAssertEqual(
            terminal.traceEventsForTesting.last?.metadata?["actualRuntimeGeneration"],
            "22"
        )
        XCTAssertEqual(
            terminal.traceEventsForTesting.last?.metadata?["runtimeGenerationSource"],
            "coordinatorSnapshot"
        )
    }

    func testBackgroundCommandRejectsDisconnectedLeaseBeforeRunnerLaunch() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-reused",
            agentTitle: "deploy@prod",
            agentLiveSessionContext: makeTunnelLiveSessionContext(),
            runtimeGeneration: 4
        )
        terminal.onTrace = { event in
            if event.state == .approved {
                terminal.runtimeConnected = false
            }
        }
        let runner = RecordingAgentBackgroundCommandRunner()
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            executionMode: .backgroundTask,
            backgroundCommandRunner: runner
        )
        let request = AgentBridgeRequest(
            id: "req-stale-background-lease",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(AgentRunCommandRequest(
                target: .runtimeID("term-reused"),
                command: "uptime",
                follow: true,
                expectedRuntimeGeneration: 4
            ))
        )

        XCTAssertThrowsError(try coordinator.runCommand(request)) { error in
            XCTAssertEqual(error as? AgentExecutionError, .terminalRuntimeLeaseChanged)
        }
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(terminal.sentInput.isEmpty)
        XCTAssertEqual(auditStore.events.map(\.state), ["failed"])
        XCTAssertEqual(
            terminal.traceEventsForTesting.last?.metadata?["runtimeConnected"],
            "false"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testApprovedAgentCommandIsSentThroughVisibleTerminal() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: AllowingAgentActionAuthorizer(),
            auditRecorder: auditStore
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-1",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(terminal.sentInput, ["uptime\n"])
        XCTAssertTrue(terminal.traceSnapshot.contains("approved"))
        XCTAssertTrue(terminal.traceSnapshot.contains("running"))
        XCTAssertEqual(events.map(\.state), [.queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput])
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "manualRequired")
        XCTAssertEqual(events.last?.metadata?["actorKind"], AgentActorKind.externalCLI.rawValue)
        XCTAssertEqual(events.last?.metadata?["actorName"], "codex")
        XCTAssertEqual(auditStore.events.map(\.state), ["running"])
        XCTAssertEqual(auditStore.events.first?.requestId, "req-1")
        XCTAssertEqual(auditStore.events.first?.actorName, "codex")
        XCTAssertEqual(auditStore.events.first?.targetRuntimeId, "term_1")
        XCTAssertEqual(auditStore.events.first?.targetTitle, "dev@example.com")
        XCTAssertEqual(auditStore.events.first?.actionKind, "runCommand")
        XCTAssertEqual(auditStore.events.first?.risk, "readOnly")
        XCTAssertEqual(auditStore.events.first?.redactedInput, "uptime")
        XCTAssertEqual(auditStore.events.first?.environment, "development")
        XCTAssertEqual(auditStore.events.first?.approvalMode, "inherit")
        XCTAssertEqual(auditStore.events.first?.policyDecision, "confirmed")
        XCTAssertEqual(auditStore.events.first?.redactionVersion, "stacio.agent-redaction.v1")
    }

    func testInteractiveConfirmationReplyBypassesShellCompletionWrapper() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_interactive",
            agentTitle: "local",
            terminalDisplaySnapshot: "Do you want to proceed with the installation? [y/n]",
            supportsAgentCompletionMarker: true
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer()
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-interactive-confirmation",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_interactive"),
                        command: "y",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(terminal.sentInput, ["y\n"])
        XCTAssertFalse(terminal.sentInput.joined().contains("stacio-agent-done"))
        XCTAssertFalse(terminal.sentInput.joined().contains("}; printf"))
    }

    func testShortCommandWithoutConfirmationPromptKeepsCompletionWrapper() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_shell",
            agentTitle: "local",
            terminalDisplaySnapshot: "mac@host / %",
            supportsAgentCompletionMarker: true
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer()
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-short-shell-command",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_shell"),
                        command: "y",
                        follow: true
                    )
                )
            )
        )

        XCTAssertTrue(terminal.sentInput.joined().contains("stacio-agent-done"))
    }

    func testStaleConfirmationPromptDoesNotTurnLaterShortCommandIntoInteractiveReply() throws {
        let completedOutput = (1...8).map { "installation output line \($0)" }.joined(separator: "\n")
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_completed_prompt",
            agentTitle: "local",
            terminalDisplaySnapshot: "Do you want to proceed? [y/n]\n\(completedOutput)\nmac@host / %",
            supportsAgentCompletionMarker: true
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer()
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-stale-confirmation",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_completed_prompt"),
                        command: "y",
                        follow: true
                    )
                )
            )
        )

        XCTAssertTrue(terminal.sentInput.joined().contains("stacio-agent-done"))
    }

    func testVisibleTerminalObservationKeepsAppKitControlsResponsive() throws {
        let clickTarget = RecordingButtonClickTarget()
        let button = NSButton(title: "取消", target: clickTarget, action: #selector(RecordingButtonClickTarget.clicked(_:)))
        button.frame = NSRect(x: 20, y: 20, width: 100, height: 32)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(button)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let mouseLocation = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: mouseLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: mouseLocation,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        NSApp.postEvent(mouseDown, atStart: false)
        NSApp.postEvent(mouseUp, atStart: false)

        let terminal = RecordingAgentTerminalTarget(runtimeID: "term_responsive", agentTitle: "local")
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer()
        )
        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-responsive-wait",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_responsive"),
                        command: "sleep 1",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(clickTarget.clickCount, 1)
    }

    func testApprovedAgentCommandStreamsTraceEventsWhileWritingTerminalInput() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: AllowingAgentActionAuthorizer()
        )
        var streamedStates: [AgentTraceState] = []

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-stream",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            ),
            emit: { event in
                streamedStates.append(event.state)
            }
        )

        XCTAssertEqual(streamedStates, [.queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput])
        XCTAssertEqual(events.map(\.state), streamedStates)
        XCTAssertEqual(terminal.sentInput, ["uptime\n"])
        XCTAssertTrue(terminal.traceSnapshot.contains("typing"))
        XCTAssertTrue(terminal.traceSnapshot.contains("running"))
    }

    func testPolicyAllowedAgentCommandSkipsApprovalWaitingTrace() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext(),
            agentAutomationPolicy: SessionAutomationPolicy(
                environment: "development",
                aiExecutionPolicy: "readOnlyAuto"
            )
        )
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-policy",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(events.map(\.state), [.queued, .approved, .typing, .running, .waitingForOutput])
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "manualRequired")
        XCTAssertFalse(terminal.traceSnapshot.contains("awaitingApproval"))
        XCTAssertTrue(terminal.traceSnapshot.contains("已按全局策略自动放行"))
        XCTAssertEqual(terminal.sentInput, ["uptime\n"])
        XCTAssertEqual(auditStore.events.first?.environment, "development")
        XCTAssertEqual(auditStore.events.first?.approvalMode, "readOnlyAuto")
        XCTAssertEqual(auditStore.events.first?.policyDecision, "autoAllowed")
        XCTAssertEqual(auditStore.events.first?.redactionVersion, "stacio.agent-redaction.v1")
    }

    func testAgentTraceEventsIncludeExecutionAndPolicyMetadata() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "prod@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext(),
            agentAutomationPolicy: SessionAutomationPolicy(
                environment: "production",
                aiExecutionPolicy: "readOnlyAuto"
            )
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-policy-metadata",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(events.map { $0.metadata?["executionMode"] }, [
            "backgroundTask",
            "backgroundTask",
            "backgroundTask"
        ])
        XCTAssertEqual(events.map { $0.metadata?["environment"] }, [
            "production",
            "production",
            "production"
        ])
        XCTAssertEqual(events.map { $0.metadata?["aiExecutionPolicy"] }, [
            "readOnlyAuto",
            "readOnlyAuto",
            "readOnlyAuto"
        ])
        XCTAssertEqual(events.map { $0.metadata?["policyDecision"] }, [
            nil,
            "autoAllowed",
            "autoAllowed"
        ])
        XCTAssertEqual(terminal.traceEventsForTesting.map { $0.metadata?["environment"] }, [
            "production",
            "production",
            "production"
        ])
    }

    func testSessionPolicyCanRequireApprovalEvenWhenGlobalPolicyWouldAutoAllow() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "prod@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext(),
            agentAutomationPolicy: SessionAutomationPolicy(
                environment: "production",
                aiExecutionPolicy: "requireEveryCommand"
            )
        )
        let authorizer = RecordingPolicyAwareAgentActionAuthorizer()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: authorizer
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-session-policy",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(authorizer.policies, [terminal.agentAutomationPolicy])
        XCTAssertEqual(events.map(\.state), [.queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput])
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "manualRequired")
        XCTAssertEqual(terminal.sentInput, ["uptime\n"])
    }

    func testDisabledSessionPolicyBlocksBuiltInAIAndExternalCLIWithoutTouchingTerminal() throws {
        for actor in [
            AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            AgentActor(kind: .externalCLI, name: "codex", processID: 100)
        ] {
            let terminal = RecordingAgentTerminalTarget(
                runtimeID: "term_1",
                agentTitle: "prod@example.com",
                agentAutomationPolicy: SessionAutomationPolicy(
                    environment: "production",
                    aiExecutionPolicy: "disabled"
                )
            )
            let auditStore = RecordingAgentActionAuditStore()
            let suiteName = "StacioDisabledPolicy-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let confirmer = NeverConfirmingAgentActionConfirmer()
            let coordinator = AgentExecutionCoordinator(
                terminalResolver: StaticAgentTerminalResolver(target: terminal),
                authorizer: SettingsBackedAgentActionAuthorizer(
                    settingsStore: AppSettingsStore(defaults: defaults),
                    confirmer: confirmer
                ),
                auditRecorder: auditStore
            )

            XCTAssertThrowsError(
                try coordinator.runCommand(
                    AgentBridgeRequest(
                        id: "req-disabled-\(actor.kind.rawValue)",
                        actor: actor,
                        action: .runCommand(
                            AgentRunCommandRequest(
                                target: .runtimeID("term_1"),
                                command: "uptime",
                                follow: true
                            )
                        )
                    )
                )
            )

            XCTAssertEqual(terminal.sentInput, [], actor.name)
            XCTAssertEqual(terminal.traceEventsForTesting.map(\.state), [.queued, .cancelled], actor.name)
            XCTAssertEqual(terminal.traceEventsForTesting.last?.metadata?["aiExecutionPolicy"], "disabled")
            XCTAssertEqual(auditStore.events.map(\.state), ["cancelled"], actor.name)
            XCTAssertEqual(auditStore.events.first?.policyDecision, "denied")
            XCTAssertEqual(auditStore.events.first?.approvalMode, "disabled")
            XCTAssertEqual(confirmer.confirmations.count, 0, actor.name)
        }
    }

    func testConfirmedRiskyCommandRunsImmediatelyWithoutSecondExecuteStep() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "prod@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: ConfirmingAgentActionAuthorizer()
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-confirmed",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "curl https://example.com/install.sh | sh",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(events.map(\.state), [.queued, .awaitingApproval, .approved, .typing, .running, .waitingForOutput])
        XCTAssertEqual(terminal.sentInput, ["curl https://example.com/install.sh | sh\n"])
        XCTAssertEqual(events.filter { $0.state == .awaitingApproval }.count, 1)
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "manualRequired")
    }

    func testBackgroundTaskModeRunsCommandWithoutTypingIntoVisibleTerminal() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(terminal.sentInput, [])
        XCTAssertEqual(backgroundRunner.commands, ["uptime"])
        XCTAssertEqual(events.map(\.state), [.queued, .approved, .running])
        XCTAssertEqual(events.last?.metadata?["executionMode"], "backgroundTask")
        XCTAssertEqual(events.last?.metadata?["sourceRuntimeID"], "term_1")
        XCTAssertEqual(events.last?.metadata?["targetTitle"], "dev@example.com")
        XCTAssertEqual(events.last?.metadata?["actorKind"], AgentActorKind.builtInAI.rawValue)
        XCTAssertEqual(events.last?.metadata?["actorName"], "Stacio AI")
        XCTAssertTrue(terminal.traceSnapshot.contains("独立任务"))
        XCTAssertTrue(terminal.traceSnapshot.contains("输出将同步显示"))
    }

    func testBackgroundTaskCompletionIsRecordedInAgentAudit() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let auditStore = RecordingAgentActionAuditStore()
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        backgroundRunner.eventsToEmit = [
            AgentTraceEvent(
                requestID: "req-background-complete",
                state: .completed,
                message: "AI 独立任务已完成。",
                redactedCommand: "uptime",
                metadata: ["executionMode": "backgroundTask"]
            )
        ]
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-complete",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(auditStore.events.map(\.state), ["running", "completed"])
        XCTAssertEqual(auditStore.events.map(\.requestId), ["req-background-complete", "req-background-complete"])
        XCTAssertEqual(auditStore.events.last?.redactedInput, "uptime")
        XCTAssertEqual(auditStore.events.last?.policyDecision, "autoAllowed")
    }

    func testCoordinatorCancelsActiveBackgroundTaskAndAppendsTrace() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-cancel",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "sleep 60",
                        follow: true
                    )
                )
            )
        )

        let event = coordinator.cancelTask(requestID: "req-background-cancel")

        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, ["req-background-cancel"])
        XCTAssertEqual(event?.state, .cancelled)
        XCTAssertEqual(event?.metadata?["actorKind"], AgentActorKind.builtInAI.rawValue)
        XCTAssertEqual(event?.metadata?["actorName"], "Stacio AI")
        XCTAssertTrue(terminal.traceSnapshot.contains("cancelled"))
        XCTAssertTrue(terminal.traceSnapshot.contains("AI 独立任务已取消"))
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "cancelled"])
        XCTAssertEqual(auditStore.events.last?.requestId, "req-background-cancel")
    }

    func testBackgroundTaskFreezesSourceGenerationAndTitleAcrossReconnectBeforeCancel() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_reused",
            agentTitle: "old-host@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext(),
            runtimeGeneration: 41
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-frozen-lease",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_reused"),
                        command: "sleep 60",
                        follow: true,
                        expectedRuntimeGeneration: 41
                    )
                )
            )
        )

        terminal.runtimeGeneration = 42
        terminal.agentTitle = "new-host@example.com"
        let cancelEvent = coordinator.cancelTask(requestID: "req-background-frozen-lease")

        XCTAssertEqual(events.last?.metadata?["sourceRuntimeGeneration"], "41")
        XCTAssertEqual(events.last?.metadata?["targetTitle"], "old-host@example.com")
        XCTAssertEqual(backgroundRunner.requests.first?.sourceRuntimeGeneration, 41)
        XCTAssertEqual(backgroundRunner.requests.first?.targetTitle, "old-host@example.com")
        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, ["req-background-frozen-lease"])
        XCTAssertEqual(cancelEvent?.metadata?["sourceRuntimeGeneration"], "41")
        XCTAssertEqual(cancelEvent?.metadata?["targetTitle"], "old-host@example.com")
        XCTAssertTrue(terminal.sentInput.isEmpty)
        XCTAssertEqual(auditStore.events.last?.targetTitle, "old-host@example.com")
    }

    func testBackgroundTaskRejectsDuplicateActiveRequestIDWithoutReplacingCancellationHandle() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_duplicate_request",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )
        let firstRequest = AgentBridgeRequest(
            id: "req-duplicate-active",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_duplicate_request"),
                    command: "sleep 60",
                    follow: true
                )
            )
        )
        _ = try coordinator.runCommand(firstRequest)
        let duplicateRequest = AgentBridgeRequest(
            id: "req-duplicate-active",
            actor: firstRequest.actor,
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_duplicate_request"),
                    command: "echo replacement",
                    follow: true
                )
            )
        )

        XCTAssertThrowsError(try coordinator.runCommand(duplicateRequest)) { error in
            XCTAssertEqual(error as? AgentExecutionError, .requestAlreadyActive)
        }
        let cancelEvent = coordinator.cancelTask(requestID: "req-duplicate-active")

        XCTAssertEqual(backgroundRunner.commands, ["sleep 60"])
        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, ["req-duplicate-active"])
        XCTAssertEqual(cancelEvent?.redactedCommand, "sleep 60")
    }

    func testBackgroundPauseDoesNotDropCancellationHandleOrClaimPausedState() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_background_pause",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )
        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-pause-unsupported",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_background_pause"),
                        command: "sleep 60",
                        follow: true
                    )
                )
            )
        )

        let pauseEvent = coordinator.pauseTask(requestID: "req-background-pause-unsupported")
        let cancelEvent = coordinator.cancelTask(requestID: "req-background-pause-unsupported")

        XCTAssertEqual(pauseEvent?.state, .waitingForOutput)
        XCTAssertEqual(pauseEvent?.metadata?["controlResult"], "unsupported")
        XCTAssertEqual(pauseEvent?.metadata?["taskStillRunning"], "true")
        XCTAssertEqual(cancelEvent?.state, .cancelled)
        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, ["req-background-pause-unsupported"])
    }

    func testBackgroundConfirmCompleteDoesNotClaimCompletionOrDropCancellationHandle() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_background_confirm",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )
        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-confirm-unsupported",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_background_confirm"),
                        command: "sleep 60",
                        follow: true
                    )
                )
            )
        )

        let completeEvent = coordinator.confirmTaskComplete(requestID: "req-background-confirm-unsupported")
        let cancelEvent = coordinator.cancelTask(requestID: "req-background-confirm-unsupported")

        XCTAssertEqual(completeEvent?.state, .waitingForOutput)
        XCTAssertEqual(completeEvent?.metadata?["controlResult"], "unsupported")
        XCTAssertEqual(completeEvent?.metadata?["taskStillRunning"], "true")
        XCTAssertEqual(cancelEvent?.state, .cancelled)
        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, ["req-background-confirm-unsupported"])
    }

    func testBackgroundTakeoverRetainsTaskWhenCancellationCannotBeConfirmed() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_background_takeover",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        backgroundRunner.returnsCancellationEvent = false
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )
        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-takeover-unconfirmed",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_background_takeover"),
                        command: "sleep 60",
                        follow: true
                    )
                )
            )
        )

        let takeoverEvent = coordinator.takeOverTask(requestID: "req-background-takeover-unconfirmed")
        let retryCancelEvent = coordinator.cancelTask(requestID: "req-background-takeover-unconfirmed")

        XCTAssertEqual(takeoverEvent?.state, .waitingForOutput)
        XCTAssertEqual(takeoverEvent?.metadata?["controlResult"], "cancellationUnconfirmed")
        XCTAssertEqual(takeoverEvent?.metadata?["taskStillRunning"], "unknown")
        XCTAssertNil(retryCancelEvent)
        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, [
            "req-background-takeover-unconfirmed",
            "req-background-takeover-unconfirmed"
        ])
    }

    func testCoordinatorPausesTrackedTaskAndAppendsTraceWithoutSendingMoreInput() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-visible-pause",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "tail -f /var/log/messages",
                        follow: true
                    )
                )
            )
        )
        let event = coordinator.pauseTask(requestID: "req-visible-pause")

        XCTAssertEqual(terminal.sentInput, ["tail -f /var/log/messages\n"])
        XCTAssertEqual(event?.state, .paused)
        XCTAssertEqual(event?.metadata?["control"], "pause")
        XCTAssertEqual(event?.metadata?["actorKind"], AgentActorKind.builtInAI.rawValue)
        XCTAssertTrue(event?.message.contains("AI 后续自动动作已暂停") ?? false)
        XCTAssertTrue(terminal.traceSnapshot.contains("paused"))
        XCTAssertTrue(terminal.traceSnapshot.contains("AI 后续自动动作已暂停"))
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "paused"])
        XCTAssertEqual(auditStore.events.last?.requestId, "req-visible-pause")
    }

    func testCoordinatorConfirmsVisibleTerminalTaskCompleteAndClosesTrackedTask() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-visible-confirm",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "tail -f /var/log/messages",
                        follow: true
                    )
                )
            )
        )

        let event = coordinator.confirmTaskComplete(requestID: "req-visible-confirm")

        XCTAssertEqual(event?.state, .completed)
        XCTAssertEqual(event?.metadata?["completionConfidence"], "userConfirmed")
        XCTAssertEqual(event?.metadata?["completionReason"], "userConfirmed")
        XCTAssertEqual(event?.metadata?["actorKind"], AgentActorKind.builtInAI.rawValue)
        XCTAssertTrue(terminal.traceSnapshot.contains("completed"))
        XCTAssertTrue(terminal.traceSnapshot.contains("已确认本步结束"))
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "completed"])
        XCTAssertEqual(auditStore.events.last?.requestId, "req-visible-confirm")
        XCTAssertNil(coordinator.confirmTaskComplete(requestID: "req-visible-confirm"))
    }

    func testCoordinatorCancelsVisibleTerminalTaskBySendingInterrupt() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-visible-cancel",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "tail -f /var/log/messages",
                        follow: true
                    )
                )
            )
        )
        let event = coordinator.cancelTask(requestID: "req-visible-cancel")

        XCTAssertEqual(terminal.sentInput, ["tail -f /var/log/messages\n", "\u{03}"])
        XCTAssertEqual(terminal.sentInputBytes.last, [3])
        XCTAssertEqual(event?.state, .cancelled)
        XCTAssertEqual(event?.metadata?["control"], "cancel")
        XCTAssertEqual(event?.metadata?["executionMode"], "visibleTerminal")
        XCTAssertEqual(event?.metadata?["actorKind"], AgentActorKind.builtInAI.rawValue)
        XCTAssertTrue(event?.message.contains("已向可见终端发送中断") ?? false)
        XCTAssertTrue(terminal.traceSnapshot.contains("cancelled"))
        XCTAssertTrue(terminal.traceSnapshot.contains("中断"))
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "cancelled"])
        XCTAssertEqual(auditStore.events.last?.requestId, "req-visible-cancel")
    }

    func testCoordinatorDoesNotSendVisibleCancelWhenTrackedRuntimeDisappears() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let resolver = MutableAgentTerminalResolver(target: terminal)
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: resolver,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            visibleTerminalCompletion: fastVisibleCompletion
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-visible-stale-cancel",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "tail -f /var/log/messages",
                        follow: true
                    )
                )
            )
        )
        resolver.target = nil

        let event = coordinator.cancelTask(requestID: "req-visible-stale-cancel")

        XCTAssertEqual(event?.state, .failed)
        XCTAssertEqual(event?.metadata?["control"], "cancel")
        XCTAssertEqual(event?.metadata?["controlResult"], "runtimeLeaseChanged")
        XCTAssertEqual(event?.metadata?["actualRuntimeGeneration"], "unavailable")
        XCTAssertEqual(event?.metadata?["runtimeConnected"], "false")
        XCTAssertEqual(terminal.sentInput, ["tail -f /var/log/messages\n"])
        XCTAssertTrue(terminal.traceSnapshot.contains("未向当前连接发送中断"))
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "failed"])
        XCTAssertNil(coordinator.cancelTask(requestID: "req-visible-stale-cancel"))
    }

    func testCoordinatorFailsClosedAndCompletesFollowStreamWhenVisibleRuntimeReconnectsBeforeCancel() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            runtimeGeneration: 7
        )
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-visible-reconnected-cancel",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "tail -f /var/log/messages",
                        follow: true,
                        expectedRuntimeGeneration: 7
                    )
                )
            )
        )
        var followedEvents: [AgentTraceEvent] = []
        var followCompleted = false
        coordinator.registerBridgeFollowStream(
            requestID: "req-visible-reconnected-cancel",
            emit: { followedEvents.append($0) },
            completion: { followCompleted = true }
        )
        terminal.runtimeGeneration = 8

        let event = coordinator.cancelTask(requestID: "req-visible-reconnected-cancel")

        XCTAssertEqual(terminal.sentInput, ["tail -f /var/log/messages\n"])
        XCTAssertEqual(event?.state, .failed)
        XCTAssertEqual(event?.metadata?["expectedRuntimeGeneration"], "7")
        XCTAssertEqual(event?.metadata?["actualRuntimeGeneration"], "8")
        XCTAssertEqual(event?.metadata?["runtimeConnected"], "true")
        XCTAssertEqual(followedEvents, [event].compactMap { $0 })
        XCTAssertTrue(followCompleted)
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "failed"])
    }

    func testVisibleTerminalControlsCannotClaimSuccessAfterRuntimeReconnect() throws {
        let controls: [(name: String, invoke: (AgentExecutionCoordinator, String) -> AgentTraceEvent?)] = [
            ("pause", { $0.pauseTask(requestID: $1) }),
            ("takeover", { $0.takeOverTask(requestID: $1) }),
            ("confirmComplete", { $0.confirmTaskComplete(requestID: $1) })
        ]

        for control in controls {
            let requestID = "req-stale-\(control.name)"
            let terminal = RecordingAgentTerminalTarget(
                runtimeID: "term_1",
                agentTitle: "dev@example.com",
                runtimeGeneration: 12
            )
            let auditStore = RecordingAgentActionAuditStore()
            let coordinator = makeVisibleCoordinator(
                target: terminal,
                authorizer: PolicyAllowedAgentActionAuthorizer(),
                auditRecorder: auditStore
            )
            _ = try coordinator.runCommand(
                AgentBridgeRequest(
                    id: requestID,
                    actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                    action: .runCommand(
                        AgentRunCommandRequest(
                            target: .runtimeID("term_1"),
                            command: "tail -f /var/log/messages",
                            follow: true,
                            expectedRuntimeGeneration: 12
                        )
                    )
                )
            )
            terminal.runtimeGeneration = 13

            let event = control.invoke(coordinator, requestID)

            XCTAssertEqual(event?.state, .failed, control.name)
            XCTAssertEqual(event?.metadata?["control"], control.name, control.name)
            XCTAssertEqual(event?.metadata?["controlResult"], "runtimeLeaseChanged", control.name)
            XCTAssertEqual(event?.metadata?["expectedRuntimeGeneration"], "12", control.name)
            XCTAssertEqual(event?.metadata?["actualRuntimeGeneration"], "13", control.name)
            XCTAssertEqual(terminal.sentInput, ["tail -f /var/log/messages\n"], control.name)
            XCTAssertEqual(auditStore.events.map(\.state), ["running", "failed"], control.name)
        }
    }

    func testCoordinatorTakeOverClosesBackgroundTaskAndMarksItUserControlled() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-takeover",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "sleep 60",
                        follow: true
                    )
                )
            )
        )
        let event = coordinator.takeOverTask(requestID: "req-background-takeover")

        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, ["req-background-takeover"])
        XCTAssertEqual(event?.state, .takenOver)
        XCTAssertEqual(event?.metadata?["control"], "takeover")
        XCTAssertEqual(event?.metadata?["executionMode"], "backgroundTask")
        XCTAssertEqual(event?.metadata?["actorKind"], AgentActorKind.builtInAI.rawValue)
        XCTAssertTrue(event?.message.contains("已切换为人工接管") ?? false)
        XCTAssertTrue(terminal.traceSnapshot.contains("takenOver"))
        XCTAssertTrue(terminal.traceSnapshot.contains("人工接管"))
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "takenOver"])
        XCTAssertEqual(auditStore.events.last?.requestId, "req-background-takeover")
    }

    func testCoordinatorTakeOverVisibleTerminalTaskStopsAIWithoutExtraInputOrBackgroundCancel() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            backgroundCommandRunner: backgroundRunner,
            visibleTerminalCompletion: fastVisibleCompletion
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-visible-takeover",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "tail -f /var/log/messages",
                        follow: true
                    )
                )
            )
        )
        let event = coordinator.takeOverTask(requestID: "req-visible-takeover")

        XCTAssertEqual(terminal.sentInput, ["tail -f /var/log/messages\n"])
        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, [])
        XCTAssertEqual(event?.state, .takenOver)
        XCTAssertEqual(event?.metadata?["control"], "takeover")
        XCTAssertEqual(event?.metadata?["executionMode"], "visibleTerminal")
        XCTAssertEqual(event?.metadata?["actorKind"], AgentActorKind.builtInAI.rawValue)
        XCTAssertTrue(event?.message.contains("可见终端") ?? false)
        XCTAssertTrue(event?.message.contains("AI 不再继续自动执行") ?? false)
        XCTAssertTrue(terminal.traceSnapshot.contains("takenOver"))
        XCTAssertTrue(terminal.traceSnapshot.contains("人工接管"))
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "takenOver"])
        XCTAssertEqual(auditStore.events.last?.requestId, "req-visible-takeover")
    }

    func testBackgroundTaskModeFailsWithoutWritingVisibleTerminalWhenTargetHasNoLiveSSHContext() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_local",
            agentTitle: "本机终端"
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        let events = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-unavailable",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_local"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(backgroundRunner.commands, [])
        XCTAssertEqual(events.map(\.state), [.queued, .approved, .failed])
        XCTAssertEqual(events.last?.message, "AI 独立任务失败：当前终端暂不支持 AI 独立任务执行。")
        XCTAssertEqual(events.last?.metadata?["executionMode"], "backgroundTask")
        XCTAssertEqual(events.last?.metadata?["sourceRuntimeID"], "term_local")
        XCTAssertEqual(events.last?.metadata?["fallbackReason"], "backgroundTaskUnavailable")
        XCTAssertEqual(auditStore.events.map(\.state), ["failed"])
        XCTAssertEqual(terminal.sentInput, [])
    }

    func testExecutionPolicyAndModeAreResolvedAtRunTime() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let authorizer = MutablePolicyAgentActionAuthorizer(requiresConfirmation: false)
        var executionMode = AgentExecutionMode.visibleTerminal
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: authorizer,
            executionMode: .visibleTerminal,
            executionModeResolver: { executionMode },
            backgroundCommandRunner: backgroundRunner,
            visibleTerminalCompletion: fastVisibleCompletion
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-dynamic-1",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )

        authorizer.requiresConfirmation = true
        executionMode = .backgroundTask
        let secondEvents = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-dynamic-2",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "df -h",
                        follow: true
                    )
                )
            )
        )

        XCTAssertEqual(terminal.sentInput, ["uptime\n"])
        XCTAssertEqual(backgroundRunner.commands, ["df -h"])
        XCTAssertTrue(secondEvents.contains { $0.state == .awaitingApproval })
        XCTAssertEqual(authorizer.confirmationChecks, [false, true])
    }

    func testAgentBridgeFollowWaitsForBackgroundTerminalResultBeforeCompleting() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )
        let request = AgentBridgeRequest(
            id: "req-bridge-follow",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "uptime",
                    follow: true
                )
            )
        )
        var streamed: [AgentTraceEvent] = []
        var completionCount = 0

        try coordinator.handleAgentBridgeRequest(
            request,
            emit: { streamed.append($0) },
            completion: { completionCount += 1 }
        )

        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(streamed.last?.state, .running)

        backgroundRunner.emit(
            AgentTraceEvent(
                requestID: request.id,
                state: .completed,
                message: "AI 独立任务已完成：up 2 days",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "terminalOutputSummary": "up 2 days"
                ]
            ),
            requestID: request.id
        )

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(streamed.last?.state, .completed)
        XCTAssertEqual(streamed.last?.metadata?["terminalOutputSummary"], "up 2 days")
    }

    func testRemoteSSHBackgroundRunnerStartsDedicatedRuntimeAndEmitsOutputTrace() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(output: "load average: 0.01\n")
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-runtime",
                command: "uptime",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "uptime",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .completed } })
        XCTAssertEqual(bridge.startedHosts, ["dev.example.com"])
        let input = try XCTUnwrap(bridge.writes.first.map { String(decoding: $0.bytes, as: UTF8.self) })
        XCTAssertEqual(try decodedBackgroundCommand(from: input), "uptime")
        XCTAssertTrue(input.contains("__STACIO_AGENT_LOG="))
        XCTAssertTrue(input.contains("__STACIO_AGENT_DONE__"))
        XCTAssertTrue(input.contains("cat \"$__STACIO_AGENT_LOG\""))
        XCTAssertFalse(input.contains(" -- "))
        XCTAssertTrue(input.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exit"))
        XCTAssertEqual(bridge.closedRuntimeIDs, ["agent_bg_1"])
        let startedEvent = emitted.first { $0.state == .waitingForOutput }
        XCTAssertTrue(startedEvent?.message.contains("已创建独立执行终端") ?? false)
        XCTAssertEqual(startedEvent?.metadata?["taskRuntimeID"], "agent_bg_1")
        XCTAssertTrue(emitted.last?.message.contains("load average: 0.01") ?? false)
        XCTAssertEqual(emitted.last?.metadata?["executionMode"], "backgroundTask")
        XCTAssertEqual(emitted.last?.metadata?["sourceRuntimeID"], "term_ssh")
        XCTAssertEqual(emitted.last?.metadata?["taskRuntimeID"], "agent_bg_1")
    }

    func testRemoteSSHBackgroundRunnerWrapsReadOnlyCompoundCommandsIntoRemoteLogScript() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(output: "__STACIO_AGENT_DONE__:0\n")
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-log-wrapper",
                command: "uname -a; cat /proc/cpuinfo | head -n 3; free -m",
                targetRuntimeID: "term_ssh",
                targetTitle: "anolis@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "uname -a; cat /proc/cpuinfo | head -n 3; free -m",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { bridge.writes.isEmpty == false })
        let input = try XCTUnwrap(bridge.writes.first.map { String(decoding: $0.bytes, as: UTF8.self) })
        XCTAssertTrue(input.contains("__STACIO_AGENT_LOG="))
        XCTAssertTrue(input.contains("mktemp"))
        XCTAssertEqual(
            try decodedBackgroundCommand(from: input),
            "uname -a; cat /proc/cpuinfo | head -n 3; free -m"
        )
        XCTAssertTrue(input.contains("cat \"$__STACIO_AGENT_LOG\""))
        XCTAssertFalse(input.contains(" -- "))
        XCTAssertTrue(input.contains("printf '\\n__STACIO_AGENT_DONE__:%s\\n'"))
        XCTAssertFalse(input.contains("sftp "))
        XCTAssertFalse(input.contains("scp "))
        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .completed } })
    }

    func testRemoteSSHBackgroundRunnerWrapsCompoundCommandWithoutRemoteBase64Dependency() throws {
        let command = "printf '%s\\n' '龙蜥 ready'; uname -a; df -h /"
        let bridge = RecordingAgentBackgroundRuntimeBridge(output: "__STACIO_AGENT_DONE__:0\n")
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-posix-wrapper",
                command: command,
                targetRuntimeID: "term_ssh",
                targetTitle: "anolis@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: command,
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { _ in }
        )

        XCTAssertTrue(waitUntil { bridge.writes.isEmpty == false })
        let input = try XCTUnwrap(bridge.writes.first.map { String(decoding: $0.bytes, as: UTF8.self) })
        XCTAssertEqual(try decodedBackgroundCommand(from: input), command)
        XCTAssertFalse(input.contains("base64"))
        XCTAssertTrue(input.contains("__STACIO_AGENT_CMD="))
        XCTAssertTrue(input.contains("sh -c \"$__STACIO_AGENT_CMD\""))
    }

    func testRemoteSSHBackgroundRunnerDetectsCompletionSentinelAfterNonUTF8Output() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(
            outputBatches: [
                [0xff, 0xfe] + Array("\n__STACIO_AGENT_DONE__:0\n".utf8)
            ],
            keepRunning: true
        )
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 0.12,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-binary-output",
                command: "cat /tmp/binary-output; printf done",
                targetRuntimeID: "term_ssh",
                targetTitle: "anolis@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "cat /tmp/binary-output; printf done",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .completed } })
        XCTAssertFalse(emitted.contains { $0.state == .failed })
        XCTAssertEqual(bridge.closedRuntimeIDs, ["agent_bg_1"])
    }

    func testRemoteSSHBackgroundRunnerDetectsCompletionAfterTrimmingLargeOutput() throws {
        let largeBatch = Array(repeating: UInt8(ascii: "x"), count: 256 * 1024 + 32)
            + Array("\n__STACIO_AGENT_DONE__:0\n".utf8)
        let bridge = RecordingAgentBackgroundRuntimeBridge(
            outputBatches: [largeBatch],
            keepRunning: true
        )
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 0.12,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-large-output",
                command: "generate-large-output",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "generate-large-output",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .completed } })
        XCTAssertFalse(emitted.contains { $0.state == .failed })
        XCTAssertEqual(bridge.closedRuntimeIDs, ["agent_bg_1"])
    }

    func testRemoteSSHBackgroundRunnerStreamsOutputBatchesBeforeCompletion() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(outputs: [
            "checking disk\n",
            "done sk-live-secret\n"
        ])
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-stream",
                command: "df -h",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "df -h",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .completed } })
        let outputEvents = emitted.filter {
            $0.state == .running && $0.message.contains("AI 独立任务输出")
        }
        XCTAssertEqual(outputEvents.map(\.message), [
            "AI 独立任务输出：checking disk",
            "AI 独立任务输出：done [redacted]"
        ])
        XCTAssertEqual(outputEvents.map { $0.metadata?["taskRuntimeID"] }, [
            "agent_bg_1",
            "agent_bg_1"
        ])
        XCTAssertEqual(outputEvents.map { $0.metadata?["terminalOutputSummary"] }, [
            "checking disk",
            "done [redacted]"
        ])
        XCTAssertEqual(emitted.last?.metadata?["terminalOutputSummary"], "checking disk\ndone [redacted]")
        guard let firstOutput = outputEvents.first,
              let firstOutputIndex = emitted.firstIndex(of: firstOutput),
              let completedIndex = emitted.firstIndex(where: { $0.state == .completed }) else {
            return
        }
        XCTAssertLessThan(
            firstOutputIndex,
            completedIndex
        )
    }

    func testRemoteSSHBackgroundRunnerSeparatesShortSummaryFromAuditedHistoryOutput() throws {
        let longOutput = "BEGIN\n"
            + String(repeating: "diagnostic detail\n", count: 700)
            + "credential sk-live-secret\nEND\n"
        let bridge = RecordingAgentBackgroundRuntimeBridge(outputs: [longOutput])
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01,
            outputLimit: 80
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-history-output",
                command: "collect-diagnostics",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio 排查助手", processID: nil),
                redactedCommand: "collect-diagnostics",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { emitted.append($0) }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .completed } })
        let completed = try XCTUnwrap(emitted.last { $0.state == .completed })
        let summary = try XCTUnwrap(completed.metadata?["terminalOutputSummary"])
        let historyOutput = try XCTUnwrap(completed.metadata?["terminalHistoryOutput"])
        XCTAssertLessThanOrEqual(summary.count, 83)
        XCTAssertGreaterThan(historyOutput.count, 8_000)
        XCTAssertTrue(historyOutput.contains("BEGIN"))
        XCTAssertTrue(historyOutput.contains("END"))
        XCTAssertTrue(historyOutput.contains("[redacted]"))
        XCTAssertFalse(historyOutput.contains("sk-live-secret"))
        XCTAssertEqual(completed.metadata?["terminalOutputAudited"], "true")
    }

    func testRemoteSSHBackgroundRunnerDoesNotExposeHistoryOutputToExternalActors() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(outputs: [
            String(repeating: "diagnostic detail\n", count: 700)
        ])
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01,
            outputLimit: 80
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-external-history",
                command: "collect-diagnostics",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .externalCLI, name: "automation", processID: 42),
                redactedCommand: "collect-diagnostics",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { emitted.append($0) }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .completed } })
        let completed = try XCTUnwrap(emitted.last { $0.state == .completed })
        XCTAssertNil(completed.metadata?["terminalHistoryOutput"])
        XCTAssertNotNil(completed.metadata?["terminalOutputSummary"])
    }

    func testRemoteSSHBackgroundRunnerFailsWhenDedicatedRuntimeTimesOut() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(outputs: [], keepRunning: true)
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 0.03,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-timeout",
                command: "sleep 60",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "sleep 60",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .failed } })
        XCTAssertFalse(emitted.contains { $0.state == .completed })
        XCTAssertEqual(bridge.closedRuntimeIDs, ["agent_bg_1"])
        XCTAssertEqual(emitted.last?.metadata?["taskRuntimeID"], "agent_bg_1")
        XCTAssertTrue(emitted.last?.message.contains("超时") ?? false)
    }

    func testRemoteSSHBackgroundRunnerRejectsNonRunningDedicatedRuntimeWithoutWritingCommand() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(
            startStatus: LiveShellStatus(
                runtimeId: "agent_bg_failed",
                status: "failed",
                diagnostic: "connection refused"
            )
        )
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-start-failed",
                command: "uptime",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "uptime",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { emitted.contains { $0.state == .failed } })
        XCTAssertEqual(bridge.startedHosts, ["dev.example.com"])
        XCTAssertEqual(bridge.writes, [])
        XCTAssertEqual(bridge.closedRuntimeIDs, ["agent_bg_failed"])
        XCTAssertEqual(emitted.last?.metadata?["taskRuntimeID"], "agent_bg_failed")
        XCTAssertTrue(emitted.last?.message.contains("连接被拒绝") ?? false)
        XCTAssertFalse(emitted.contains { $0.state == .waitingForOutput })
    }

    func testRemoteSSHBackgroundRunnerCancelsDedicatedRuntimeByRequestID() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(outputs: [], keepRunning: true)
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-cancel",
                command: "sleep 60",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "sleep 60",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { bridge.startedHosts == ["dev.example.com"] })
        let cancelEvent = runner.cancel(requestID: "req-background-cancel")

        XCTAssertEqual(bridge.closedRuntimeIDs, ["agent_bg_1"])
        XCTAssertEqual(cancelEvent?.state, .cancelled)
        XCTAssertEqual(cancelEvent?.metadata?["taskRuntimeID"], "agent_bg_1")
        XCTAssertTrue(cancelEvent?.message.contains("已取消") ?? false)
    }

    func testRemoteSSHBackgroundRunnerDoesNotEmitTerminalStateAfterCancellation() throws {
        let bridge = RecordingAgentBackgroundRuntimeBridge(outputs: [], keepRunning: true)
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-cancel-race",
                command: "sleep 60",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "sleep 60",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(waitUntil { bridge.startedHosts == ["dev.example.com"] })
        XCTAssertTrue(waitUntil { bridge.writes.isEmpty == false })
        let cancelEvent = runner.cancel(requestID: "req-background-cancel-race")
        XCTAssertEqual(cancelEvent?.state, .cancelled)

        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        XCTAssertFalse(emitted.contains { $0.state == .failed }, emitted.map(\.state.rawValue).joined(separator: ","))
        XCTAssertFalse(emitted.contains { $0.state == .completed }, emitted.map(\.state.rawValue).joined(separator: ","))
        XCTAssertEqual(bridge.closedRuntimeIDs, ["agent_bg_1"])
    }

    func testRemoteSSHBackgroundRunnerCancellationWinsWhileCompletionCloseIsInFlight() throws {
        let bridge = BlockingCompletionCloseAgentBackgroundRuntimeBridge()
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []
        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-complete-cancel-race",
                command: "printf done",
                targetRuntimeID: "term_ssh",
                sourceRuntimeGeneration: 17,
                targetTitle: "old-host@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "printf done",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { emitted.append($0) }
        )

        XCTAssertTrue(bridge.waitUntilCompletionCloseStarted())
        let cancelEvent = runner.cancel(requestID: "req-background-complete-cancel-race")
        bridge.releaseCompletionClose()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))

        XCTAssertEqual(cancelEvent?.state, .cancelled)
        XCTAssertEqual(cancelEvent?.metadata?["sourceRuntimeGeneration"], "17")
        XCTAssertEqual(cancelEvent?.metadata?["targetTitle"], "old-host@example.com")
        XCTAssertFalse(emitted.contains { $0.state == .completed })
        XCTAssertFalse(emitted.contains { $0.state == .failed })
        XCTAssertEqual(bridge.closeCallCount, 2)
    }

    func testCoordinatorRetainsBackgroundCancellationHandleWhenRuntimeCloseFails() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_background_close_retry",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext(),
            runtimeGeneration: 31
        )
        let bridge = FailOnceCloseAgentBackgroundRuntimeBridge()
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 1,
            pollInterval: 0.01
        )
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            auditRecorder: auditStore,
            executionMode: .backgroundTask,
            backgroundCommandRunner: runner
        )
        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-close-retry",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_background_close_retry"),
                        command: "sleep 60",
                        follow: true,
                        expectedRuntimeGeneration: 31
                    )
                )
            )
        )
        XCTAssertTrue(bridge.waitUntilCommandWritten())

        let firstCancel = coordinator.cancelTask(requestID: "req-background-close-retry")
        let secondCancel = coordinator.cancelTask(requestID: "req-background-close-retry")

        XCTAssertEqual(firstCancel?.state, .waitingForOutput)
        XCTAssertEqual(firstCancel?.metadata?["controlResult"], "runtimeCloseFailed")
        XCTAssertEqual(firstCancel?.metadata?["sourceRuntimeGeneration"], "31")
        XCTAssertEqual(secondCancel?.state, .cancelled)
        XCTAssertEqual(bridge.closeCallCount, 2)
        XCTAssertEqual(auditStore.events.map(\.state), ["running", "cancelled"])
    }

    func testRemoteSSHBackgroundRunnerHonorsCancellationBeforeRuntimeRegisters() throws {
        let bridge = BlockingStartAgentBackgroundRuntimeBridge()
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 0.12,
            pollInterval: 0.01
        )
        var emitted: [AgentTraceEvent] = []

        try runner.runBackgroundCommand(
            AgentBackgroundCommandRequest(
                requestID: "req-background-pre-cancel",
                command: "sleep 60",
                targetRuntimeID: "term_ssh",
                targetTitle: "dev@example.com",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                redactedCommand: "sleep 60",
                liveSessionContext: makeTunnelLiveSessionContext()
            ),
            emit: { event in
                emitted.append(event)
            }
        )

        XCTAssertTrue(bridge.waitUntilStartRequested())
        let cancelEvent = runner.cancel(requestID: "req-background-pre-cancel")
        bridge.releaseStart()

        XCTAssertEqual(cancelEvent?.state, .cancelled)
        XCTAssertEqual(cancelEvent?.metadata?["sourceRuntimeID"], "term_ssh")
        XCTAssertNil(cancelEvent?.metadata?["taskRuntimeID"])
        XCTAssertTrue(waitUntil { bridge.closedRuntimeIDs == ["agent_bg_1"] })
        XCTAssertEqual(bridge.writes, [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(emitted.contains { $0.state == .waitingForOutput }, emitted.map(\.state.rawValue).joined(separator: ","))
        XCTAssertFalse(emitted.contains { $0.state == .failed }, emitted.map(\.state.rawValue).joined(separator: ","))
        XCTAssertFalse(emitted.contains { $0.state == .completed }, emitted.map(\.state.rawValue).joined(separator: ","))
    }

    func testRemoteSSHBackgroundRunnerRejectsDuplicatePendingRequestID() throws {
        let bridge = BlockingStartAgentBackgroundRuntimeBridge()
        let runner = RemoteSSHAgentBackgroundCommandRunner(
            runtimeBridge: bridge,
            timeout: 0.12,
            pollInterval: 0.01
        )
        let firstRequest = AgentBackgroundCommandRequest(
            requestID: "req-background-duplicate-pending",
            command: "sleep 60",
            targetRuntimeID: "term_ssh",
            targetTitle: "dev@example.com",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            redactedCommand: "sleep 60",
            liveSessionContext: makeTunnelLiveSessionContext()
        )
        try runner.runBackgroundCommand(firstRequest, emit: { _ in })
        XCTAssertTrue(bridge.waitUntilStartRequested())

        XCTAssertThrowsError(
            try runner.runBackgroundCommand(firstRequest, emit: { _ in })
        ) { error in
            XCTAssertEqual(error as? AgentExecutionError, .requestAlreadyActive)
        }

        XCTAssertEqual(
            runner.cancel(requestID: "req-background-duplicate-pending")?.state,
            .cancelled
        )
        bridge.releaseStart()
        XCTAssertTrue(waitUntil { bridge.closedRuntimeIDs == ["agent_bg_1"] })
    }

    func testBlockedAgentCommandDoesNotTouchTerminalInput() throws {
        let terminal = RecordingAgentTerminalTarget(runtimeID: "term_1", agentTitle: "prod@example.com")
        let auditStore = RecordingAgentActionAuditStore()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: DenyingAgentActionAuthorizer(),
            auditRecorder: auditStore
        )

        XCTAssertThrowsError(
            try coordinator.runCommand(
                AgentBridgeRequest(
                    id: "req-1",
                    actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                    action: .runCommand(
                        AgentRunCommandRequest(
                            target: .runtimeID("term_1"),
                            command: "rm -rf /tmp/build",
                            follow: true
                        )
                    )
                )
            )
        )
        XCTAssertEqual(terminal.sentInput, [])
        XCTAssertTrue(terminal.traceSnapshot.contains("awaitingApproval"))
        XCTAssertTrue(terminal.traceSnapshot.contains("cancelled"))
        XCTAssertEqual(auditStore.events.map(\.state), ["cancelled"])
        XCTAssertEqual(auditStore.events.first?.risk, "destructive")
        XCTAssertEqual(auditStore.events.first?.redactedInput, "rm -rf /tmp/build")
        XCTAssertEqual(auditStore.events.first?.policyDecision, "denied")
        XCTAssertEqual(auditStore.events.first?.redactionVersion, "stacio.agent-redaction.v1")
    }

    func testListSessionsReturnsStructuredTerminalTargets() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: AllowingAgentActionAuthorizer(),
            sessionLister: RecordingAgentTerminalSessionLister(sessions: [
                AgentTerminalSessionSummary(
                    runtimeID: "term_1",
                    title: "dev@example.com",
                    kind: "remote",
                    environment: "development",
                    isCurrent: true,
                    currentDirectory: "/srv/app",
                    subtitle: "remote · /srv/app"
                )
            ])
        )

        let events = try coordinator.handleAgentBridgeRequest(
            AgentBridgeRequest(
                id: "req-sessions",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
                action: .listSessions
            )
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.state, .completed)
        XCTAssertEqual(events.first?.metadata?["type"], "terminalSession")
        XCTAssertEqual(events.first?.metadata?["runtimeID"], "term_1")
        XCTAssertEqual(events.first?.metadata?["title"], "dev@example.com")
        XCTAssertEqual(events.first?.metadata?["kind"], "remote")
        XCTAssertEqual(events.first?.metadata?["environment"], "development")
        XCTAssertEqual(events.first?.metadata?["current"], "true")
        XCTAssertEqual(events.first?.metadata?["currentDirectory"], "/srv/app")
        XCTAssertEqual(events.first?.metadata?["subtitle"], "remote · /srv/app")
    }

    func testManagedCapabilityListRejectsSameRuntimeAfterReconnect() {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term-reused",
            agentTitle: "reconnected",
            runtimeGeneration: 9
        )
        let registry = LocalAgentCapabilityRegistry()
        registry.register(
            capabilityID: "scope-list-old-lease",
            targetRuntimeGenerations: ["term-reused": 8],
            processGeneration: 1
        )
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: AllowingAgentActionAuthorizer(),
            sessionLister: RecordingAgentTerminalSessionLister(sessions: [
                AgentTerminalSessionSummary(
                    runtimeID: "term-reused",
                    connectionGeneration: 9,
                    title: "reconnected",
                    kind: "remote",
                    environment: "production",
                    isCurrent: true
                )
            ]),
            localAgentCapabilityRegistry: registry
        )

        let events = coordinator.listSessions(
            AgentBridgeRequest(
                id: "req-list-old-lease",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
                action: .listSessions,
                capabilityID: "scope-list-old-lease"
            )
        )

        XCTAssertEqual(events.map(\.state), [.failed])
        XCTAssertEqual(events.first?.message, AgentExecutionError.capabilityRejected.localizedDescription)
    }

    func testHandleAgentBridgeRequestCancelsBackgroundTask() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com",
            agentLiveSessionContext: makeTunnelLiveSessionContext()
        )
        let backgroundRunner = RecordingAgentBackgroundCommandRunner()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: StaticAgentTerminalResolver(target: terminal),
            authorizer: PolicyAllowedAgentActionAuthorizer(),
            executionMode: .backgroundTask,
            backgroundCommandRunner: backgroundRunner
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-background-cancel",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "sleep 60",
                        follow: true
                    )
                )
            )
        )
        let events = try coordinator.handleAgentBridgeRequest(
            AgentBridgeRequest(
                id: "req-control",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
                action: .cancelTask("req-background-cancel")
            )
        )

        XCTAssertEqual(backgroundRunner.cancelledRequestIDs, ["req-background-cancel"])
        XCTAssertEqual(events.map(\.state), [.cancelled])
        XCTAssertEqual(events.first?.requestID, "req-background-cancel")
    }

    func testHandleAgentBridgeRequestPausesTrackedTask() throws {
        let terminal = RecordingAgentTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let coordinator = makeVisibleCoordinator(
            target: terminal,
            authorizer: PolicyAllowedAgentActionAuthorizer()
        )

        _ = try coordinator.runCommand(
            AgentBridgeRequest(
                id: "req-visible-pause",
                actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
                action: .runCommand(
                    AgentRunCommandRequest(
                        target: .runtimeID("term_1"),
                        command: "uptime",
                        follow: true
                    )
                )
            )
        )
        let events = try coordinator.handleAgentBridgeRequest(
            AgentBridgeRequest(
                id: "req-control",
                actor: AgentActor(kind: .externalCLI, name: "codex", processID: 100),
                action: .pauseTask("req-visible-pause")
            )
        )

        XCTAssertEqual(events.map(\.state), [.paused])
        XCTAssertEqual(events.first?.requestID, "req-visible-pause")
    }
}

@MainActor
private final class RecordingAgentTerminalTarget: AgentTerminalTarget {
    let runtimeID: String
    var agentTitle: String
    let agentLiveSessionContext: TunnelLiveSessionContext?
    let agentAutomationPolicy: SessionAutomationPolicy
    let agentTerminalDisplaySnapshot: String
    let supportsAgentCompletionMarker: Bool
    var runtimeGeneration: UInt64
    var runtimeConnected: Bool
    var onTrace: ((AgentTraceEvent) -> Void)?
    private(set) var sentInput: [String] = []
    private(set) var sentInputBytes: [[UInt8]] = []
    private var traceEvents: [AgentTraceEvent] = []
    private(set) var interactionLocked = false

    var agentRuntimeGeneration: UInt64 { runtimeGeneration }
    var isAgentRuntimeConnected: Bool { runtimeConnected }

    init(
        runtimeID: String,
        agentTitle: String,
        agentLiveSessionContext: TunnelLiveSessionContext? = nil,
        agentAutomationPolicy: SessionAutomationPolicy = .default,
        terminalDisplaySnapshot: String = "",
        supportsAgentCompletionMarker: Bool = false,
        runtimeGeneration: UInt64 = 0,
        runtimeConnected: Bool = true
    ) {
        self.runtimeID = runtimeID
        self.agentTitle = agentTitle
        self.agentLiveSessionContext = agentLiveSessionContext
        self.agentAutomationPolicy = agentAutomationPolicy
        self.agentTerminalDisplaySnapshot = terminalDisplaySnapshot
        self.supportsAgentCompletionMarker = supportsAgentCompletionMarker
        self.runtimeGeneration = runtimeGeneration
        self.runtimeConnected = runtimeConnected
    }

    func appendAgentTrace(_ event: AgentTraceEvent) {
        traceEvents.append(event)
        onTrace?(event)
    }

    func setAgentInteractionLocked(_ locked: Bool) {
        interactionLocked = locked
    }

    func sendInput(_ bytes: [UInt8]) {
        sentInputBytes.append(bytes)
        sentInput.append(String(decoding: bytes, as: UTF8.self))
    }

    var traceSnapshot: String {
        traceEvents
            .map { "\($0.state.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }

    var traceEventsForTesting: [AgentTraceEvent] {
        traceEvents
    }
}

@MainActor
private final class RecordingButtonClickTarget: NSObject {
    private(set) var clickCount = 0

    @objc
    func clicked(_ sender: Any?) {
        clickCount += 1
    }
}

@MainActor
private struct StaticAgentTerminalResolver: AgentTerminalResolving {
    let target: AgentTerminalTarget

    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        self.target
    }
}

@MainActor
private final class MutableAgentTerminalResolver: AgentTerminalResolving {
    var target: AgentTerminalTarget?

    init(target: AgentTerminalTarget?) {
        self.target = target
    }

    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        guard let resolved = self.target else {
            throw AgentExecutionError.terminalNotFound
        }
        return resolved
    }
}

private struct AllowingAgentActionAuthorizer: AgentActionAuthorizing {
    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(allowed: true, reason: "allowed", risk: AgentActionClassifier.risk(forCommand: command))
    }
}

private struct PolicyAllowedAgentActionAuthorizer: AgentActionAuthorizing {
    func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        false
    }

    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "allowed by policy",
            risk: AgentActionClassifier.risk(forCommand: command),
            requiredUserConfirmation: false
        )
    }
}

private final class MutablePolicyAgentActionAuthorizer: AgentActionAuthorizing {
    var requiresConfirmation: Bool
    private(set) var confirmationChecks: [Bool] = []

    init(requiresConfirmation: Bool) {
        self.requiresConfirmation = requiresConfirmation
    }

    func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        confirmationChecks.append(requiresConfirmation)
        return requiresConfirmation
    }

    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: requiresConfirmation ? "confirmed" : "allowed by policy",
            risk: AgentActionClassifier.risk(forCommand: command),
            requiredUserConfirmation: requiresConfirmation
        )
    }
}

private final class RecordingPolicyAwareAgentActionAuthorizer: AgentActionAuthorizing {
    private(set) var policies: [SessionAutomationPolicy] = []

    func requiresUserConfirmation(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) -> Bool {
        policies.append(automationPolicy)
        return automationPolicy.aiExecutionPolicy == "requireEveryCommand"
    }

    func authorize(
        actor: AgentActor,
        command: String,
        targetTitle: String,
        automationPolicy: SessionAutomationPolicy
    ) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "confirmed",
            risk: AgentActionClassifier.risk(forCommand: command),
            requiredUserConfirmation: automationPolicy.aiExecutionPolicy == "requireEveryCommand"
        )
    }

    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        try authorize(actor: actor, command: command, targetTitle: targetTitle, automationPolicy: .default)
    }
}

private struct ConfirmingAgentActionAuthorizer: AgentActionAuthorizing {
    func requiresUserConfirmation(actor: AgentActor, command: String, targetTitle: String) -> Bool {
        true
    }

    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(
            allowed: true,
            reason: "confirmed",
            risk: AgentActionClassifier.risk(forCommand: command),
            requiredUserConfirmation: true
        )
    }
}

private final class NeverConfirmingAgentActionConfirmer: AgentActionConfirming {
    private(set) var confirmations: [AgentActionConfirmation] = []

    func confirmAgentAction(_ confirmation: AgentActionConfirmation, parentWindow: NSWindow?) -> Bool {
        confirmations.append(confirmation)
        return false
    }
}

private struct DenyingAgentActionAuthorizer: AgentActionAuthorizing {
    func authorize(actor: AgentActor, command: String, targetTitle: String) throws -> AgentAuthorizationDecision {
        AgentAuthorizationDecision(allowed: false, reason: "denied", risk: AgentActionClassifier.risk(forCommand: command))
    }
}

private struct RecordingAgentTerminalSessionLister: AgentTerminalSessionListing {
    let sessions: [AgentTerminalSessionSummary]

    func listAgentTerminalSessions() -> [AgentTerminalSessionSummary] {
        sessions
    }
}

@MainActor
private final class RecordingAgentBackgroundCommandRunner: AgentBackgroundCommandRunning {
    private(set) var commands: [String] = []
    private(set) var requests: [AgentBackgroundCommandRequest] = []
    private(set) var cancelledRequestIDs: [String] = []
    var eventsToEmit: [AgentTraceEvent] = []
    var returnsCancellationEvent = true
    private var emittersByRequestID: [String: @MainActor (AgentTraceEvent) -> Void] = [:]

    func runBackgroundCommand(
        _ request: AgentBackgroundCommandRequest,
        emit: @escaping @MainActor (AgentTraceEvent) -> Void
    ) throws {
        commands.append(request.command)
        requests.append(request)
        emittersByRequestID[request.requestID] = emit
        eventsToEmit.forEach(emit)
    }

    func emit(_ event: AgentTraceEvent, requestID: String) {
        emittersByRequestID[requestID]?(event)
    }

    func cancel(requestID: String) -> AgentTraceEvent? {
        cancelledRequestIDs.append(requestID)
        guard returnsCancellationEvent else { return nil }
        return AgentTraceEvent(
            requestID: requestID,
            state: .cancelled,
            message: "AI 独立任务已取消。",
            redactedCommand: nil
        )
    }
}

private final class RecordingAgentBackgroundRuntimeBridge: AgentBackgroundRuntimeBridging {
    struct Write: Equatable {
        let runtimeID: String
        let bytes: [UInt8]
    }

    private let outputBatches: [Data]
    private let keepRunning: Bool
    private let startStatus: LiveShellStatus
    private var pollCount = 0
    private(set) var startedHosts: [String] = []
    private(set) var writes: [Write] = []
    private(set) var closedRuntimeIDs: [String] = []

    init(output: String) {
        self.outputBatches = [Data(output.utf8)]
        self.keepRunning = false
        self.startStatus = LiveShellStatus(runtimeId: "agent_bg_1", status: "running", diagnostic: "")
    }

    init(outputs: [String], keepRunning: Bool = false) {
        self.outputBatches = outputs.map { Data($0.utf8) }
        self.keepRunning = keepRunning
        self.startStatus = LiveShellStatus(runtimeId: "agent_bg_1", status: "running", diagnostic: "")
    }

    init(outputBatches: [[UInt8]], keepRunning: Bool = false) {
        self.outputBatches = outputBatches.map { Data($0) }
        self.keepRunning = keepRunning
        self.startStatus = LiveShellStatus(runtimeId: "agent_bg_1", status: "running", diagnostic: "")
    }

    init(startStatus: LiveShellStatus) {
        self.outputBatches = []
        self.keepRunning = false
        self.startStatus = startStatus
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        startedHosts.append(config.host)
        return startStatus
    }

    func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws {
        writes.append(Write(runtimeID: runtimeID, bytes: bytes))
    }

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        pollCount += 1
        if keepRunning {
            return LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "")
        }
        let status = pollCount >= max(outputBatches.count, 1) ? "completed" : "running"
        return LiveShellStatus(runtimeId: runtimeID, status: status, diagnostic: "")
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        let outputIndex = pollCount - 1
        let bytes = outputBatches.indices.contains(outputIndex) ? outputBatches[outputIndex] : Data()
        return TerminalOutputBatch(runtimeId: runtimeID, bytes: bytes, droppedByteCount: 0)
    }

    func closeTerminalRuntime(runtimeID: String) throws {
        closedRuntimeIDs.append(runtimeID)
    }
}

private final class BlockingStartAgentBackgroundRuntimeBridge: AgentBackgroundRuntimeBridging {
    private let startRequested = DispatchSemaphore(value: 0)
    private let releaseStartSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var writes: [RecordingAgentBackgroundRuntimeBridge.Write] = []
    private(set) var closedRuntimeIDs: [String] = []

    func waitUntilStartRequested(timeout: TimeInterval = 1) -> Bool {
        startRequested.wait(timeout: .now() + timeout) == .success
    }

    func releaseStart() {
        releaseStartSignal.signal()
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        startRequested.signal()
        _ = releaseStartSignal.wait(timeout: .now() + 1)
        return LiveShellStatus(runtimeId: "agent_bg_1", status: "running", diagnostic: "")
    }

    func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws {
        lock.lock()
        writes.append(RecordingAgentBackgroundRuntimeBridge.Write(runtimeID: runtimeID, bytes: bytes))
        lock.unlock()
    }

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "")
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        TerminalOutputBatch(runtimeId: runtimeID, bytes: Data(), droppedByteCount: 0)
    }

    func closeTerminalRuntime(runtimeID: String) throws {
        lock.lock()
        closedRuntimeIDs.append(runtimeID)
        lock.unlock()
    }
}

private final class BlockingCompletionCloseAgentBackgroundRuntimeBridge: AgentBackgroundRuntimeBridging {
    private let completionCloseStarted = DispatchSemaphore(value: 0)
    private let releaseCompletionCloseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closeCalls = 0

    var closeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCalls
    }

    func waitUntilCompletionCloseStarted(timeout: TimeInterval = 1) -> Bool {
        completionCloseStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseCompletionClose() {
        releaseCompletionCloseSignal.signal()
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: "agent_bg_race", status: "running", diagnostic: "")
    }

    func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws {}

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "completed", diagnostic: "")
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        TerminalOutputBatch(
            runtimeId: runtimeID,
            bytes: Data("__STACIO_AGENT_DONE__:0\n".utf8),
            droppedByteCount: 0
        )
    }

    func closeTerminalRuntime(runtimeID: String) throws {
        lock.lock()
        closeCalls += 1
        let call = closeCalls
        lock.unlock()
        if call == 1 {
            completionCloseStarted.signal()
            _ = releaseCompletionCloseSignal.wait(timeout: .now() + 1)
        }
    }
}

private final class FailOnceCloseAgentBackgroundRuntimeBridge: AgentBackgroundRuntimeBridging {
    private let commandWritten = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var closeCalls = 0

    var closeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCalls
    }

    func waitUntilCommandWritten(timeout: TimeInterval = 1) -> Bool {
        commandWritten.wait(timeout: .now() + timeout) == .success
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: "agent_bg_close_retry", status: "running", diagnostic: "")
    }

    func writeTerminalInput(runtimeID: String, bytes: [UInt8]) throws {
        commandWritten.signal()
    }

    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        LiveShellStatus(runtimeId: runtimeID, status: "running", diagnostic: "")
    }

    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        TerminalOutputBatch(runtimeId: runtimeID, bytes: Data(), droppedByteCount: 0)
    }

    func closeTerminalRuntime(runtimeID: String) throws {
        lock.lock()
        closeCalls += 1
        let shouldFail = closeCalls == 1
        lock.unlock()
        if shouldFail {
            throw SshRuntimeError.Transport(message: "close failed")
        }
    }
}

private func makeTunnelLiveSessionContext() -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: "dev.example.com",
            port: 22,
            username: "deploy",
            authMethod: .agent,
            connectTimeoutMs: 10_000
        ),
        secret: .agent,
        expectedFingerprintSHA256: "SHA256:test"
    )
}

private func decodedBackgroundCommand(from script: String) throws -> String {
    if let commandLine = script.components(separatedBy: .newlines)
        .map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { $0.hasPrefix("__STACIO_AGENT_CMD=") })
    {
        return try decodePOSIXSingleQuotedShellAssignment(commandLine, variableName: "__STACIO_AGENT_CMD")
    }
    let prefix = "__STACIO_AGENT_CMD_B64='"
    let line = try XCTUnwrap(script.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .first { $0.hasPrefix(prefix) })
    let encoded = String(line.dropFirst(prefix.count).dropLast())
    let data = try XCTUnwrap(Data(base64Encoded: encoded))
    return String(decoding: data, as: UTF8.self)
}

private func decodePOSIXSingleQuotedShellAssignment(_ line: String, variableName: String) throws -> String {
    let prefix = "\(variableName)="
    XCTAssertTrue(line.hasPrefix(prefix))
    var remainder = String(line.dropFirst(prefix.count))
    var decoded = ""
    while remainder.isEmpty == false {
        guard remainder.hasPrefix("'") else {
            XCTFail("Expected POSIX single-quoted chunk in \(line)")
            return decoded
        }
        remainder.removeFirst()
        guard let endIndex = remainder.firstIndex(of: "'") else {
            XCTFail("Unterminated POSIX single-quoted chunk in \(line)")
            return decoded
        }
        decoded += remainder[..<endIndex]
        remainder = String(remainder[remainder.index(after: endIndex)...])
        if remainder.hasPrefix("\\''") {
            decoded += "'"
            remainder.removeFirst(2)
        }
    }
    return decoded
}

private final class RecordingAgentActionAuditStore: AgentActionAuditRecording {
    private(set) var events: [AgentActionAuditEvent] = []

    func recordAgentActionEvent(_ event: AgentActionAuditEvent) throws -> AgentActionAuditRecord? {
        events.append(event)
        return nil
    }
}
