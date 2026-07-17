import StacioAgentBridge
import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class AgentRealtimeFollowTests: XCTestCase {
    func testFollowStreamWaitsForBroadcastOutputBeforeCompletingVisibleTerminalCommand() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-follow",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "uname -a",
                    follow: true
                )
            )
        )
        var streamed: [AgentTraceEvent] = []

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("Darwin dev 25.0\n".utf8))
        }
        let events = try coordinator.runCommand(request, emit: { streamed.append($0) })

        XCTAssertEqual(events.map(\.state), [.queued, .approved, .typing, .running, .waitingForOutput, .completed])
        XCTAssertEqual(streamed.map(\.state), [.queued, .approved, .typing, .running, .waitingForOutput, .completed])
        XCTAssertEqual(terminal.sentInput, ["uname -a\n"])
        XCTAssertEqual(terminal.traceStates, [.queued, .approved, .typing, .running, .waitingForOutput, .completed])
        XCTAssertEqual(events.first(where: { $0.state == .waitingForOutput })?.metadata?["terminalOutputSummary"], "Darwin dev 25.0")
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "Darwin dev 25.0")
        XCTAssertTrue(terminal.traceSnapshot.contains("本次命令已完成"))
    }

    func testVisibleCommandAllowsIdleCompletionWhenFinalOutputArrivesAtMaximumDuration() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(runtimeID: "term_late", agentTitle: "dev@example.com")
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 0.05)
        )
        let request = AgentBridgeRequest(
            id: "req-late-output",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(target: .runtimeID("term_late"), command: "collect metrics", follow: true))
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) {
            hub.publishOutput(runtimeID: "term_late", bytes: Array("sample 1\n".utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
            hub.publishOutput(runtimeID: "term_late", bytes: Array("summary: healthy\n".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "outputIdle")
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "sample 1\nsummary: healthy")
    }

    func testAuditEndMarkerSplitAcrossOutputBatchesCompletesWithMarkerFreeSummary() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(runtimeID: "term_audit", agentTitle: "dev@example.com")
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.5, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-audit-split",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(target: .runtimeID("term_audit"), command: "stacio-remote audit", follow: true))
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_audit", bytes: Array("STACIO_AUDIT_BEGIN\ndisk: ok\nSTACIO_AUD".utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            hub.publishOutput(runtimeID: "term_audit", bytes: Array("IT_END\n$ ".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "disk: ok")
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "explicitMarker")
        XCTAssertEqual(events.last?.metadata?["completionReason"], "auditEndMarker")
        XCTAssertFalse(events.contains { event in
            event.message.contains("STACIO_AUDIT")
                || event.metadata?["terminalOutputSummary"]?.contains("STACIO_AUDIT") == true
        })
    }

    func testAuditEndMarkerCompletesBeforeIdleTimeout() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(runtimeID: "term_fast_audit", agentTitle: "dev@example.com")
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 1, maximumDuration: 2)
        )
        let request = AgentBridgeRequest(
            id: "req-audit-fast",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(target: .runtimeID("term_fast_audit"), command: "stacio-remote audit", follow: true))
        )
        let startedAt = Date()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            hub.publishOutput(
                runtimeID: "term_fast_audit",
                bytes: Array("STACIO_AUDIT_BEGIN\nready\nSTACIO_AUDIT_END\n".utf8)
            )
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "ready")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testLongRunningVisibleCommandDoesNotCompleteFromIdleOutput() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 0.05)
        )
        let request = AgentBridgeRequest(
            id: "req-long",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "tail -f /var/log/system.log",
                    follow: true
                )
            )
        )
        var streamed: [AgentTraceEvent] = []

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("line 1\n".utf8))
        }
        let events = try coordinator.runCommand(request, emit: { streamed.append($0) })

        XCTAssertEqual(events.map(\.state), [.queued, .approved, .typing, .running, .waitingForOutput, .waitingForOutput])
        XCTAssertEqual(streamed.last?.state, .waitingForOutput)
        XCTAssertEqual(events.first(where: { $0.metadata?["completionConfidence"] == "streaming" })?.metadata?["terminalOutputSummary"], "line 1")
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "manualRequired")
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "line 1")
        XCTAssertFalse(terminal.traceSnapshot.contains("本次命令已完成"))
    }

    func testExplicitShellPromptCompletesCommandEvenWhenManualClassificationWouldOtherwisePause() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_prompt_manual",
            agentTitle: "root@172.16.10.250"
        )
        terminal.onSendInput = {
            terminal.finishCommandForTesting(output: "line 1\nroot@user:~# ")
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: TerminalOutputBroadcastHub(),
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 0.2)
        )
        let request = AgentBridgeRequest(
            id: "req-manual-prompt",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(
                target: .runtimeID("term_prompt_manual"),
                command: "tail -f /var/log/messages",
                follow: true
            ))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("line 1") == true)
    }

    func testScreenshotCPUInspectionCommandReturnsOutputAndCompletesAtPrompt() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_cpu_full",
            agentTitle: "root@172.16.10.250"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.5, maximumDuration: 1)
        )
        let command = "uptime && echo '---- CPU cores ----' && nproc && echo '---- CPU usage snapshot ----' && top -b -n 1 | head -n 20 && echo '---- Top CPU processes ----' && ps -eo pid,ppid,user,stat,pcpu,pmem,comm,args --sort=-pcpu | head -n 10"
        let request = AgentBridgeRequest(
            id: "req-cpu-full",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(target: .runtimeID("term_cpu_full"), command: command, follow: true))
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            hub.publishOutput(
                runtimeID: "term_cpu_full",
                bytes: Array("load average: 0.27\n%Cpu(s): 2.0 us, 4.0 sy\nPID USER %CPU COMMAND\n1373834 root 300 unix_chkpwd\nroot@user:~# ".utf8)
            )
            hub.publishCommandFinished(runtimeID: "term_cpu_full")
        }

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("unix_chkpwd") == true)
        XCTAssertFalse(events.last?.message.contains("可能仍在运行") == true)
    }

    func testPartialBroadcastFallsBackToAuthoritativeTranscriptForFiniteMpstatCommand() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_mpstat",
            agentTitle: "root@172.16.10.250"
        )
        let hub = TerminalOutputBroadcastHub()
        terminal.onSendInput = {
            hub.publishOutput(runtimeID: "term_mpstat", bytes: Array("uptime && mpstat -P ALL 1 3\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                terminal.appendTranscriptForTesting(
                    output: "07:44:33 AM all 0.67 0.00 2.04 0.00\nPID PPID COMMAND %CPU %MEM\n1389956 1388970 ps 300 0.0\nroot@user:~# "
                )
            }
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 0.2)
        )
        let command = "uptime && echo && mpstat -P ALL 1 3 && echo && ps -eo pid,ppid,comm,%cpu,%mem --sort=-%cpu | head -n 15"
        let request = AgentBridgeRequest(
            id: "req-mpstat",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(target: .runtimeID("term_mpstat"), command: command, follow: true))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("1389956 1388970 ps 300") == true)
        XCTAssertFalse(events.last?.message.contains("可能仍在运行") == true)
    }

    func testCombinedBatchTopCompletesFromPlainPromptAndReturnsOutputWithoutManualPause() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_top_prompt",
            agentTitle: "root@172.16.10.250"
        )
        terminal.onSendInput = {
            terminal.appendTranscriptForTesting(
                output: "top - 08:13:40 up 22 days, load average: 0.15\n%Cpu(s): 3.0 us, 10.1 sy, 86.9 id\n1394539 root 8.3 top\nroot@user:~# "
            )
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: TerminalOutputBroadcastHub(),
            visibleTerminalCompletion: .init(idleInterval: 1, maximumDuration: 2)
        )
        let request = AgentBridgeRequest(
            id: "req-top-prompt",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(
                target: .runtimeID("term_top_prompt"),
                command: "top -bn1 | head -n 20",
                follow: true
            ))
        )

        let startedAt = Date()
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("1394539 root 8.3 top") == true)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
        XCTAssertFalse(events.last?.message.contains("可能仍在运行") == true)
    }

    func testBatchTopCommandReturnsTerminalOutputInsteadOfBeingTreatedAsInteractive() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let command = "printf 'CPU\\n'; top -b -n 1 | head -n 5"
        let request = AgentBridgeRequest(
            id: "req-top-batch",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: command,
                    follow: true
                )
            )
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("CPU\nTasks: 10 total\n".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "CPU\nTasks: 10 total")
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "observedIdle")
    }

    func testCombinedBatchTopOptionsDoNotRequireManualCompletion() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(runtimeID: "term_top_combined", agentTitle: "dev@example.com")
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let command = "uptime && top -bn1 | head -n 20"
        let request = AgentBridgeRequest(
            id: "req-top-combined",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(target: .runtimeID("term_top_combined"), command: command, follow: true))
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_top_combined", bytes: Array("top - 05:56:09 load average: 0.17\n".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "outputIdle")
    }

    func testUserInputDuringVisibleCommandMarksObservationAmbiguous() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-mixed",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "pwd",
                    follow: true
                )
            )
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("/srv/app\n".utf8))
            hub.publishUserInput(runtimeID: "term_1", bytes: Array("whoami\n".utf8))
            hub.publishOutput(runtimeID: "term_1", bytes: Array("deploy\n".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .waitingForOutput)
        XCTAssertEqual(events.last?.metadata?["completionConfidence"], "ambiguousUserInput")
        XCTAssertNil(events.last?.metadata?["terminalOutputSummary"])
        XCTAssertFalse(events.contains { $0.state == .completed })
        XCTAssertFalse(events.last?.message.contains("deploy") == true)
    }

    func testVisibleCommandIgnoresBroadcastOutputBeforeAICommandBoundary() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_1",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        hub.publishOutput(runtimeID: "term_1", bytes: Array("stale user output\n".utf8))
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-boundary",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(
                AgentRunCommandRequest(
                    target: .runtimeID("term_1"),
                    command: "pwd",
                    follow: true
                )
            )
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            hub.publishOutput(runtimeID: "term_1", bytes: Array("/srv/app\n".utf8))
        }
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "/srv/app")
        XCTAssertFalse(events.contains { $0.metadata?["terminalOutputSummary"]?.contains("stale user output") == true })
    }

    func testVisibleCommandCapturesFastOutputPublishedDuringCommandWrite() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_fast",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        terminal.onSendInput = {
            hub.publishOutput(
                runtimeID: "term_fast",
                bytes: Array("8\nCPU(s): 8\nroot@user:~# ".utf8)
            )
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 0.05)
        )
        let request = AgentBridgeRequest(
            id: "req-fast-write",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(
                target: .runtimeID("term_fast"),
                command: "nproc && lscpu",
                follow: true
            ))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "8\nCPU(s): 8\nroot@user:~#")
    }

    func testVisibleCommandCompletesImmediatelyWhenShellPromptOSC7Returns() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_prompt",
            agentTitle: "dev@example.com"
        )
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 1, maximumDuration: 2)
        )
        let request = AgentBridgeRequest(
            id: "req-prompt",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(target: .runtimeID("term_prompt"), command: "uptime", follow: true))
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            hub.publishOutput(
                runtimeID: "term_prompt",
                bytes: Array("load average: 0.04\n\u{001B}]7;file://host/home/root\u{0007}root@host:~# ".utf8)
            )
        }
        let startedAt = Date()
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertEqual(events.last?.metadata?["terminalOutputSummary"], "load average: 0.04")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testVisibleCommandCompletesFromTerminalConfirmedPromptEvent() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(runtimeID: "term_confirmed", agentTitle: "dev@example.com")
        let hub = TerminalOutputBroadcastHub()
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: hub,
            visibleTerminalCompletion: .init(idleInterval: 1, maximumDuration: 2)
        )
        let request = AgentBridgeRequest(
            id: "req-confirmed-prompt",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(target: .runtimeID("term_confirmed"), command: "uptime", follow: true))
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            hub.publishOutput(runtimeID: "term_confirmed", bytes: Array("load average: 0.04\nroot@host:~# ".utf8))
            hub.publishCommandFinished(runtimeID: "term_confirmed")
        }
        let startedAt = Date()
        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.5)
    }

    func testVisibleCommandFallsBackToTerminalCompletionSnapshotWhenBroadcastIsMissing() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(runtimeID: "term_snapshot", agentTitle: "dev@example.com")
        terminal.onSendInput = {
            terminal.finishCommandForTesting(output: "Mem: 15Gi 944Mi 8.7Gi\nSwap: 4.0Gi 0B 4.0Gi\n")
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: TerminalOutputBroadcastHub(),
            visibleTerminalCompletion: .init(idleInterval: 1, maximumDuration: 2)
        )
        let request = AgentBridgeRequest(
            id: "req-snapshot",
            actor: AgentActor(kind: .externalCLI, name: "codex", processID: 10),
            action: .runCommand(.init(target: .runtimeID("term_snapshot"), command: "free -h", follow: true))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertEqual(
            events.last?.metadata?["terminalOutputSummary"],
            "Mem: 15Gi 944Mi 8.7Gi\nSwap: 4.0Gi 0B 4.0Gi"
        )
    }

    func testVisibleCommandFallsBackToIncrementalTranscriptWhenOutputBroadcastAndPromptDetectionAreMissing() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(runtimeID: "term_cpu", agentTitle: "root@172.16.10.250")
        terminal.onSendInput = {
            terminal.appendTranscriptForTesting(
                output: "=== CPU 基本信息 ===\n8\nCPU(s): 8\nModel name: Intel(R) Xeon(R) CPU E5-2670 v3\nroot@user:~# "
            )
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: TerminalOutputBroadcastHub(),
            visibleTerminalCompletion: .init(idleInterval: 0.02, maximumDuration: 0.2)
        )
        let command = "echo '=== CPU 基本信息 ==='; nproc; lscpu | egrep 'Model name|CPU\\(s\\)|Thread|Core|Socket|MHz|max MHz|min MHz'"
        let request = AgentBridgeRequest(
            id: "req-cpu-transcript",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(target: .runtimeID("term_cpu"), command: command, follow: true))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("CPU(s): 8") == true)
        XCTAssertFalse(events.last?.message.contains("可能仍在运行") == true)
    }

    func testVisibleScreenshotPromptCompletesFromRenderedDisplayWhenTranscriptLags() throws {
        let terminal = RealtimeFollowRecordingTerminalTarget(
            runtimeID: "term_rendered_prompt",
            agentTitle: "FengLee@FengStor"
        )
        terminal.onSendInput = {
            terminal.replaceDisplayForTesting(
                output: "top - 19:31:54 up 3 days, load average: 5.90\n%Cpu(s): 3.3 si\n842957 root 231.8 java\nFengLee@FengStor:~$ "
            )
        }
        let coordinator = AgentExecutionCoordinator(
            terminalResolver: RealtimeFollowStaticTerminalResolver(target: terminal),
            authorizer: RealtimeFollowAllowingAuthorizer(),
            visibleTerminalOutputHub: TerminalOutputBroadcastHub(),
            visibleTerminalCompletion: .init(idleInterval: 0.5, maximumDuration: 1)
        )
        let request = AgentBridgeRequest(
            id: "req-rendered-prompt",
            actor: AgentActor(kind: .builtInAI, name: "Stacio AI", processID: nil),
            action: .runCommand(.init(
                target: .runtimeID("term_rendered_prompt"),
                command: "top -bn1 | head -n 20",
                follow: true
            ))
        )

        let events = try coordinator.runCommand(request)

        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.metadata?["completionReason"], "shellPromptObserved")
        XCTAssertTrue(events.last?.metadata?["terminalOutputSummary"]?.contains("842957 root 231.8 java") == true)
        XCTAssertFalse(events.last?.message.contains("可能仍在运行") == true)
    }
}

@MainActor
private final class RealtimeFollowRecordingTerminalTarget: AgentTerminalTarget {
    let runtimeID: String
    let agentTitle: String
    let agentLiveSessionContext: TunnelLiveSessionContext? = nil
    var onSendInput: (() -> Void)?
    private(set) var sentInput: [String] = []
    private(set) var traceEvents: [AgentTraceEvent] = []
    private(set) var agentCommandCompletionGeneration: UInt64 = 0
    private(set) var agentTerminalOutputTranscript: String = ""
    private(set) var agentTerminalDisplaySnapshot: String = ""

    init(runtimeID: String, agentTitle: String) {
        self.runtimeID = runtimeID
        self.agentTitle = agentTitle
    }

    func appendAgentTrace(_ event: AgentTraceEvent) {
        traceEvents.append(event)
    }

    func sendInput(_ bytes: [UInt8]) {
        sentInput.append(String(decoding: bytes, as: UTF8.self))
        onSendInput?()
    }

    func finishCommandForTesting(output: String) {
        agentTerminalOutputTranscript += output
        agentCommandCompletionGeneration &+= 1
    }

    func appendTranscriptForTesting(output: String) {
        agentTerminalOutputTranscript += output
    }

    func replaceDisplayForTesting(output: String) {
        agentTerminalDisplaySnapshot = output
    }

    var traceStates: [AgentTraceState] {
        traceEvents.map(\.state)
    }

    var traceSnapshot: String {
        traceEvents
            .map { "\($0.state.rawValue): \($0.message)" }
            .joined(separator: "\n")
    }
}

@MainActor
private struct RealtimeFollowStaticTerminalResolver: AgentTerminalResolving {
    let target: AgentTerminalTarget

    func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
        self.target
    }
}

private struct RealtimeFollowAllowingAuthorizer: AgentActionAuthorizing {
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
