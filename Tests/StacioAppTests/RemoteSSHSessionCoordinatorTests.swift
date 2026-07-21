import StacioCoreBindings
import XCTest
@testable import StacioApp

@MainActor
final class RemoteSSHSessionCoordinatorTests: XCTestCase {
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

    private func reconnectInBackground(
        _ reconnecter: RemoteTerminalReconnecting,
        title: String,
        automatically: Bool = false
    ) throws -> LiveShellStatus {
        let backgroundReconnecter = try XCTUnwrap(reconnecter as? RemoteTerminalBackgroundReconnecting)
        var outcome: Result<LiveShellStatus, Error>?
        backgroundReconnecter.reconnectRemoteTerminalInBackground(
            title: title,
            automatically: automatically
        ) { result in
            outcome = result
        }
        XCTAssertTrue(waitUntil { outcome != nil })
        return try XCTUnwrap(outcome).get()
    }

    func testStartRemoteSessionBuildsContextStartsLiveShellAndOpensWorkspacePane() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        let status = try coordinator.start(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)

        XCTAssertEqual(status.status, "connecting")
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_live" })
        XCTAssertEqual(shellBridge.startedConfigs.map(\.host), ["example.com"])
        XCTAssertEqual(shellBridge.expectedFingerprints, ["SHA256:test"])
        XCTAssertEqual(contextStore.current()?.config.host, "example.com")
        XCTAssertEqual(workspace.pendingTitles, ["deploy@example.com"])
        XCTAssertEqual(pane.liveSessionContext?.config.host, "example.com")
        XCTAssertFalse(String(describing: contextStore).contains("super-secret"))
    }

    func testStartRemoteSessionDoesNotFallbackToAgentAfterAuthenticationFailure() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let contextBuilder = AgentFallbackTunnelContextBuilder(template: context)
        let shellBridge = AgentFallbackLiveShellStarter()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: contextBuilder,
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.start(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)

        XCTAssertTrue(waitUntil { shellBridge.startedConfigs.count == 1 })
        XCTAssertEqual(shellBridge.startedConfigs.map(\.authMethod), [context.config.authMethod])
        XCTAssertEqual(contextBuilder.requestedConfigs.map(\.authMethod), [context.config.authMethod])
        XCTAssertNil(contextStore.current())
        XCTAssertEqual(pane.runtimeID, "pending_test")
    }

    func testStartRemoteSessionUsesPasswordRecoveryWhenSSHAgentHasNoIdentity() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let contextBuilder = AgentFallbackTunnelContextBuilder(template: context)
        let shellBridge = AgentFallbackLiveShellStarter(
            firstError: SshRuntimeError.Transport(
                message: "[Session(-34)] no identities found in the ssh agent"
            )
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: contextBuilder,
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let agentConfig = SshConnectionConfig(
            host: context.config.host,
            port: context.config.port,
            username: context.config.username,
            authMethod: .agent,
            connectTimeoutMs: context.config.connectTimeoutMs
        )
        let recoveredConfig = SshConnectionConfig(
            host: context.config.host,
            port: context.config.port,
            username: context.config.username,
            authMethod: .password(credentialRef: "recovered-password"),
            connectTimeoutMs: context.config.connectTimeoutMs
        )

        _ = try coordinator.openSessionTab(
            config: agentConfig,
            title: "deploy@example.com",
            credentialRecovery: { recoveredConfig }
        )
        let pane = try XCTUnwrap(workspace.openedPanes.first)

        XCTAssertTrue(waitUntil { pane.runtimeID == "term_agent" })
        XCTAssertEqual(shellBridge.startedConfigs.map(\.authMethod), [
            agentConfig.authMethod,
            recoveredConfig.authMethod
        ])
        XCTAssertEqual(contextStore.current()?.config.authMethod, recoveredConfig.authMethod)
    }

    func testStartRemoteSessionUsesProxyJumpRuntimeWhenContextHasProxyJump() throws {
        let proxyJump = proxyJumpRuntimeConfig()
        let context = tunnelContext(proxyJump: proxyJump)
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_proxy", status: "running", diagnostic: "running")
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        let status = try coordinator.start(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)

        XCTAssertEqual(status.status, "connecting")
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_proxy" })
        XCTAssertTrue(shellBridge.expectedFingerprints.isEmpty)
        XCTAssertEqual(shellBridge.proxyJumpConfigs.map(\.host), ["example.com"])
        XCTAssertEqual(shellBridge.proxyJumpHosts, ["bastion.example.com"])
        XCTAssertEqual(contextStore.current()?.proxyJump?.jumpConfig.host, "bastion.example.com")
    }

    func testStartRemoteSessionPassesAutomationPolicyToWorkspacePane() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: RecordingLiveShellStarter(
                status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
            ),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let policy = SessionAutomationPolicy(environment: "production", aiExecutionPolicy: "commandCard")

        _ = try coordinator.start(config: context.config, title: "deploy@example.com", automationPolicy: policy)

        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertEqual(workspace.pendingAutomationPolicies, [policy])
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_live" })
        XCTAssertEqual(pane.automationPolicy, policy)
    }

    func testStartRemoteSessionIncludesStartupPlanInWorkspaceBanner() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: RecordingLiveShellStarter(
                status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
            ),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let policy = SessionAutomationPolicy(
            environment: "production",
            aiExecutionPolicy: "commandCard",
            startupCommand: "cd /srv/app && docker compose ps",
            environmentVariables: ["APP_ENV=prod", "STACIO_TRACE=1"]
        )

        _ = try coordinator.start(config: context.config, title: "deploy@example.com", automationPolicy: policy)

        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_live" })
        XCTAssertTrue(pane.didDisplayStartupBannerForTesting)
        let banner = SSHSessionStartupBanner(
            context: context,
            title: "deploy@example.com",
            runtimeID: "term_live",
            automationPolicy: policy
        ).rendered()
        XCTAssertTrue(banner.contains("Startup plan:"))
        XCTAssertTrue(banner.contains("APP_ENV=prod STACIO_TRACE=1 cd /srv/app && docker compose ps"))
        XCTAssertTrue(banner.contains("not executed automatically"))
    }

    func testFailedLiveShellStartDoesNotStoreContextOrOpenPane() {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: RecordingLiveShellStarter(error: SshRuntimeError.Transport(message: "network failed")),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        XCTAssertNoThrow(try coordinator.start(config: context.config, title: "deploy@example.com"))
        let pane = try? XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane?.lifecycleState == .disconnected })
        XCTAssertNil(contextStore.current())
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testStartDoesNotStartRuntimeWhenWorkspaceIsUnavailable() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        var workspace: RecordingRemoteWorkspaceOpening? = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_orphan", status: "running", diagnostic: "running")
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: try XCTUnwrap(workspace),
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        workspace = nil

        XCTAssertThrowsError(try coordinator.start(config: context.config, title: "deploy@example.com")) { error in
            guard case RemoteTerminalLifecycleError.reconnectUnavailable = error else {
                return XCTFail("Expected reconnectUnavailable, got \(error)")
            }
        }

        XCTAssertTrue(shellBridge.startedConfigs.isEmpty)
        XCTAssertNil(contextStore.current())
    }

    func testStartRejectsNonRunningLiveShellStatusWithoutStoringContextOrOpeningPane() {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: RecordingLiveShellStarter(
                status: LiveShellStatus(
                    runtimeId: "term_failed",
                    status: "failed",
                    diagnostic: "connection refused"
                )
            ),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        XCTAssertNoThrow(try coordinator.start(config: context.config, title: "deploy@example.com"))
        let pane = try? XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane?.lifecycleState == .disconnected })
        XCTAssertEqual(pane?.lifecycleMessageForTesting, "连接失败：SSH 连接被拒绝")
        XCTAssertNil(contextStore.current())
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
    }

    func testStartRemoteSessionWritesSanitizedLifecycleLogs() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let logStore = RecordingRemoteSSHLogStore()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: RecordingLiveShellStarter(
                status: LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
            ),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" },
            appLog: logStore
        )

        _ = try coordinator.start(config: context.config, title: "deploy@example.com")
        XCTAssertTrue(waitUntil {
            logStore.lines.contains { $0.contains("ssh.session.start.succeeded") }
        })

        let joined = logStore.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("ssh.session.start.request mode=background endpoint=example.com:22 auth=password"))
        XCTAssertTrue(joined.contains("ssh.session.start.succeeded mode=background endpoint=example.com:22 runtime=term_live"))
        XCTAssertFalse(joined.contains("super-secret"))
        XCTAssertFalse(joined.contains("password-ref"))
    }

    func testFailedRemoteSessionStartWritesDiagnosticLogWithoutOpeningPane() {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let logStore = RecordingRemoteSSHLogStore()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: RecordingLiveShellStarter(error: SshRuntimeError.Transport(message: "network failed")),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" },
            appLog: logStore
        )

        XCTAssertNoThrow(try coordinator.start(config: context.config, title: "deploy@example.com"))
        XCTAssertTrue(waitUntil {
            logStore.lines.contains { $0.contains("ssh.session.start.failed") }
        })

        let joined = logStore.lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("ssh.session.start.request mode=background endpoint=example.com:22 auth=password"))
        XCTAssertTrue(joined.contains("ssh.session.start.failed mode=background endpoint=example.com:22 diagnostic="))
        XCTAssertTrue(joined.contains("network failed"))
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
        XCTAssertNil(contextStore.current())
    }

    func testOpenSessionTabReturnsBeforeSlowRuntimeStartAndShowsConnectingPane() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = SlowLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_async", status: "running", diagnostic: "running"),
            delay: 0.25
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        let startedAt = Date()
        let status = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com")
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.08)
        XCTAssertTrue(status.runtimeId.hasPrefix("pending_"))
        XCTAssertEqual(status.status, "connecting")
        XCTAssertEqual(workspace.pendingTitles, ["deploy@example.com"])
        XCTAssertTrue(workspace.openedStatuses.isEmpty)
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertEqual(pane.lifecycleState, .connecting)
        XCTAssertEqual(pane.lifecycleMessageForTesting, L10n.TerminalLifecycle.connecting)
    }

    func testStartAlsoReturnsBeforeSlowRuntimeStartAndShowsConnectingPane() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = SlowLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_start_async", status: "running", diagnostic: "running"),
            delay: 0.25
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        let startedAt = Date()
        let status = try coordinator.start(config: context.config, title: "deploy@example.com")
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.08)
        XCTAssertEqual(status.status, "connecting")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertEqual(pane.lifecycleState, .connecting)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_start_async" })
    }

    func testPersistedSSHConnectTimeoutRejectsNonIntegerAndBooleanValues() {
        XCTAssertNil(SSHConnectionDefaults.connectTimeoutMs(fromConfigJSON: #"{"connectTimeoutMs":-1}"#))
        XCTAssertNil(SSHConnectionDefaults.connectTimeoutMs(fromConfigJSON: #"{"connectTimeoutMs":true}"#))
        XCTAssertNil(SSHConnectionDefaults.connectTimeoutMs(fromConfigJSON: #"{"connectTimeoutMs":1500.5}"#))
        XCTAssertEqual(
            SSHConnectionDefaults.connectTimeoutMs(fromConfigJSON: #"{"connectTimeoutMs":45000}"#),
            45_000
        )
    }

    func testOpenSessionTabClearsStaleDisconnectedBannerBeforeRuntimeStarts() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let oldDiagnostic = "SSH 无法到达主机 (os error 65)"
        workspace.preexistingFailureDiagnostic = oldDiagnostic
        let shellBridge = SlowLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_async", status: "running", diagnostic: "running"),
            delay: 0.25
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        let status = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com")

        XCTAssertEqual(status.status, "connecting")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertEqual(pane.lifecycleState, .connecting)
        XCTAssertEqual(pane.lifecycleMessageForTesting, L10n.TerminalLifecycle.connecting)
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains(oldDiagnostic))
    }

    func testOpenSessionTabInitialNonRunningStatusShowsCurrentFailure() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = SlowLiveShellStarter(
            status: LiveShellStatus(
                runtimeId: "term_async_failed",
                status: "failed",
                diagnostic: "connection refused"
            ),
            delay: 0.01
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com")

        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil {
            shellBridge.startedConfigCount == 1
        })
        XCTAssertTrue(waitUntil { pane.lifecycleState == .disconnected })
        XCTAssertEqual(pane.lifecycleMessageForTesting, "连接失败：SSH 连接被拒绝")
        XCTAssertTrue(pane.lifecycleMessageForTesting.contains("连接被拒绝"))
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains("connection refused"))
        XCTAssertFalse(pane.lifecycleMessageForTesting.contains(L10n.TerminalLifecycle.disconnected))
        XCTAssertFalse(pane.terminalOutputTranscript.contains("连接被拒绝"))
        XCTAssertFalse(pane.terminalOutputTranscript.contains("connection refused"))
        XCTAssertFalse(pane.terminalOutputTranscript.contains("会话已停止"))
        XCTAssertFalse(pane.terminalOutputTranscript.contains("按 R 重新连接会话"))
        XCTAssertNil(contextStore.current())
    }

    func testOpenSessionTabPassesAutomationPolicyToConnectingPane() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: SlowLiveShellStarter(
                status: LiveShellStatus(runtimeId: "term_async", status: "running", diagnostic: "running"),
                delay: 0.25
            ),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let policy = SessionAutomationPolicy(environment: "production", aiExecutionPolicy: "commandCard")

        _ = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com", automationPolicy: policy)

        XCTAssertEqual(workspace.pendingAutomationPolicies, [policy])
        XCTAssertEqual(workspace.openedPanes.first?.automationPolicy, policy)
    }

    func testOpenSessionTabPreservesStartupPlanWithoutWritingClientBanner() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: SlowLiveShellStarter(
                status: LiveShellStatus(runtimeId: "term_async", status: "running", diagnostic: "running"),
                delay: 0.01
            ),
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let policy = SessionAutomationPolicy(
            environment: "production",
            aiExecutionPolicy: "commandCard",
            startupCommand: "cd /srv/app && docker compose ps",
            environmentVariables: ["APP_ENV=prod", "STACIO_TRACE=1"]
        )

        _ = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com", automationPolicy: policy)

        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil {
            pane.runtimeID == "term_async"
        })
        XCTAssertEqual(pane.automationPolicy, policy)
        XCTAssertEqual(pane.terminalOutputTranscript, "")
        XCTAssertFalse(pane.terminalOutputTranscript.contains("Startup plan:"))
        XCTAssertFalse(pane.terminalOutputTranscript.contains("APP_ENV=prod STACIO_TRACE=1 cd /srv/app && docker compose ps"))
        XCTAssertFalse(pane.terminalOutputTranscript.contains("not executed automatically"))
    }

    func testOpenSessionTabPublishesLiveContextBeforeMainThreadAttachRuns() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = BlockingLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_async", status: "running", diagnostic: "running")
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com")

        XCTAssertTrue(shellBridge.waitUntilStartRequested())
        shellBridge.releaseStart()

        let deadline = Date().addingTimeInterval(1)
        while contextStore.current() == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(contextStore.current()?.config.host, "example.com")
        XCTAssertNil(workspace.openedPanes.first?.liveSessionContext)

        XCTAssertTrue(waitUntil {
            workspace.openedPanes.first?.liveSessionContext?.config.host == "example.com"
        })
    }

    func testOpenSessionTabClosesRuntimeWhenPendingPaneClosesBeforeStartupCompletes() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = BlockingLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_orphan", status: "running", diagnostic: "running")
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com")

        XCTAssertTrue(shellBridge.waitUntilStartRequested())
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        pane.closeTerminal()
        workspace.openedPanes.removeAll()
        shellBridge.releaseStart()

        XCTAssertTrue(waitUntil {
            shellBridge.closedRuntimeIDs == ["term_orphan"]
        })
        XCTAssertNil(contextStore.current())
    }

    func testOpenSessionTabDoesNotStartRuntimeWhenWorkspaceIsUnavailable() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        var workspace: RecordingRemoteWorkspaceOpening? = RecordingRemoteWorkspaceOpening()
        let shellBridge = BlockingLiveShellStarter(
            status: LiveShellStatus(runtimeId: "term_orphan", status: "running", diagnostic: "running")
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: try XCTUnwrap(workspace),
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        workspace = nil

        XCTAssertThrowsError(try coordinator.openSessionTab(config: context.config, title: "deploy@example.com")) { error in
            guard case RemoteTerminalLifecycleError.reconnectUnavailable = error else {
                return XCTFail("Expected reconnectUnavailable, got \(error)")
            }
        }
        let didStartRuntime = shellBridge.waitUntilStartRequested(timeout: 0.1)
        if didStartRuntime {
            shellBridge.releaseStart()
        }

        XCTAssertFalse(didStartRuntime)
        XCTAssertNil(contextStore.current())
    }


    func testReconnecterRestartsRuntimeWithoutOpeningAnotherWorkspacePane() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            statuses: [
                LiveShellStatus(runtimeId: "term_initial", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_reconnected", status: "running", diagnostic: "running")
            ]
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.start(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_initial" })
        let reconnecter = try XCTUnwrap(workspace.reconnecters.first ?? nil)
        let status = try reconnectInBackground(reconnecter, title: "deploy@example.com")

        XCTAssertEqual(status.runtimeId, "term_reconnected")
        XCTAssertEqual(shellBridge.startedConfigs.map(\.host), ["example.com", "example.com"])
        XCTAssertEqual(workspace.openedPanes.count, 1)
        XCTAssertEqual(workspace.pendingTitles, ["deploy@example.com"])
    }

    func testReconnecterPreservesProxyJumpSelectionAndResolver() throws {
        let proxyJump = proxyJumpRuntimeConfig()
        let context = tunnelContext(proxyJump: proxyJump)
        let contextBuilder = RecordingProxyAwareTunnelContextBuilder(context: context)
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            statuses: [
                LiveShellStatus(runtimeId: "term_proxy_initial", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_proxy_reconnected", status: "running", diagnostic: "running")
            ]
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: contextBuilder,
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )
        let selection = SSHProxyJumpSelection.session(id: "session_bastion")
        var resolvedSessionIDs: [String] = []
        let resolver: (String) throws -> SessionRecord? = { id in
            resolvedSessionIDs.append(id)
            return savedProxyJumpSession(id: id)
        }

        _ = try coordinator.start(
            config: context.config,
            title: "deploy@example.com",
            proxyJumpSelection: selection,
            proxyJumpSessionResolver: resolver
        )
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_proxy_initial" })
        let reconnecter = try XCTUnwrap(workspace.reconnecters.first ?? nil)
        let status = try reconnectInBackground(reconnecter, title: "deploy@example.com")

        XCTAssertEqual(status.runtimeId, "term_proxy_reconnected")
        XCTAssertEqual(contextBuilder.proxyJumpSelections, [selection, selection])
        XCTAssertEqual(resolvedSessionIDs, ["session_bastion", "session_bastion"])
        XCTAssertEqual(shellBridge.proxyJumpConfigs.map(\.host), ["example.com", "example.com"])
        XCTAssertTrue(shellBridge.startedConfigs.isEmpty)
    }

    func testRemoteSSHReconnectReturnsPendingWithoutBlockingMainActor() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = SequencedDelayLiveShellStarter(entries: [
            (
                delay: 0,
                status: LiveShellStatus(runtimeId: "term_initial_async", status: "running", diagnostic: "running")
            ),
            (
                delay: 0.25,
                status: LiveShellStatus(runtimeId: "term_reconnected_async", status: "running", diagnostic: "running")
            )
        ])
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.openSessionTab(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_initial_async" })

        let startedAt = Date()
        let pendingStatus = try pane.reconnectTerminal()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.08)
        XCTAssertEqual(pendingStatus.status, "connecting")
        XCTAssertEqual(pane.lifecycleState, .reconnecting)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_reconnected_async" })
        XCTAssertEqual(pane.lifecycleState, .running)
    }

    func testClosingPaneDuringReconnectKeepsAcceptedContextAndClosesLateRuntime() throws {
        let initialContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "initial.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:initial"
        )
        let lateContext = TunnelLiveSessionContext(
            config: SshConnectionConfig(
                host: "late.example.com",
                port: 22,
                username: "deploy",
                authMethod: .agent,
                connectTimeoutMs: 10_000
            ),
            secret: .agent,
            expectedFingerprintSHA256: "SHA256:late"
        )
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = SequencedDelayLiveShellStarter(entries: [
            (
                delay: 0,
                status: LiveShellStatus(runtimeId: "term_initial", status: "running", diagnostic: "running")
            ),
            (
                delay: 0.15,
                status: LiveShellStatus(runtimeId: "term_after_close", status: "running", diagnostic: "running")
            )
        ])
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: SequencedTunnelContextBuilder(contexts: [initialContext, lateContext]),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.openSessionTab(config: initialContext.config, title: "deploy@initial.example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_initial" })
        XCTAssertEqual(contextStore.current()?.config.host, "initial.example.com")

        _ = try pane.reconnectTerminal()
        XCTAssertTrue(waitUntil { shellBridge.startedRuntimeCount == 2 })
        pane.closeTerminal()

        XCTAssertTrue(waitUntil { shellBridge.closedRuntimeIDs.contains("term_after_close") })
        XCTAssertEqual(contextStore.current()?.config.host, "initial.example.com")
    }

    func testReconnecterExtendsTimeoutFromLastSuccessfulShellStartDuration() throws {
        let context = tunnelContext(connectTimeoutMs: 10_000)
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            statuses: [
                LiveShellStatus(runtimeId: "term_initial", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_reconnected", status: "running", diagnostic: "running")
            ]
        )
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let clock = ScriptedRemoteSSHClock(dates: [
            baseDate,
            baseDate.addingTimeInterval(12),
            baseDate.addingTimeInterval(12),
            baseDate.addingTimeInterval(12)
        ])
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: EchoTunnelContextBuilder(template: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" },
            clock: clock.currentDate
        )

        _ = try coordinator.start(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_initial" })
        let reconnecter = try XCTUnwrap(workspace.reconnecters.first ?? nil)
        _ = try reconnectInBackground(reconnecter, title: "deploy@example.com")

        XCTAssertEqual(shellBridge.startedConfigs.map(\.connectTimeoutMs), [10_000, 18_000])
    }

    func testReconnecterCapsAdaptiveTimeoutAtSixtySeconds() throws {
        let context = tunnelContext(connectTimeoutMs: 20_000)
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            statuses: [
                LiveShellStatus(runtimeId: "term_initial", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_reconnected", status: "running", diagnostic: "running")
            ]
        )
        let baseDate = Date(timeIntervalSince1970: 2_000)
        let clock = ScriptedRemoteSSHClock(dates: [
            baseDate,
            baseDate.addingTimeInterval(80),
            baseDate.addingTimeInterval(80),
            baseDate.addingTimeInterval(80)
        ])
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: EchoTunnelContextBuilder(template: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" },
            clock: clock.currentDate
        )

        _ = try coordinator.start(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_initial" })
        let reconnecter = try XCTUnwrap(workspace.reconnecters.first ?? nil)
        _ = try reconnectInBackground(reconnecter, title: "deploy@example.com")

        XCTAssertEqual(shellBridge.startedConfigs.map(\.connectTimeoutMs), [20_000, 60_000])
    }

    func testAutomaticReconnectBackoffIntervalsDoNotAffectManualReconnect() throws {
        let context = tunnelContext()
        let contextStore = TunnelLiveSessionStore()
        let workspace = RecordingRemoteWorkspaceOpening()
        let shellBridge = RecordingLiveShellStarter(
            statuses: [
                LiveShellStatus(runtimeId: "term_initial", status: "running", diagnostic: "running"),
                LiveShellStatus(runtimeId: "term_manual", status: "running", diagnostic: "running")
            ]
        )
        let coordinator = RemoteSSHSessionCoordinator(
            contextBuilder: RecordingTunnelContextBuilder(context: context),
            liveShellStarter: shellBridge,
            contextStore: contextStore,
            workspace: workspace,
            databasePathProvider: { "/tmp/Stacio-test.sqlite" }
        )

        _ = try coordinator.start(config: context.config, title: "deploy@example.com")
        let pane = try XCTUnwrap(workspace.openedPanes.first)
        XCTAssertTrue(waitUntil { pane.runtimeID == "term_initial" })
        let reconnecter = try XCTUnwrap(workspace.reconnecters.first ?? nil)

        XCTAssertEqual(reconnecter.automaticReconnectDelaySeconds(), 0.25)
        XCTAssertEqual(reconnecter.automaticReconnectDelaySeconds(), 0.75)
        XCTAssertEqual(reconnecter.automaticReconnectDelaySeconds(), 1.5)
        XCTAssertEqual(reconnecter.automaticReconnectDelaySeconds(), 3)
        XCTAssertEqual(reconnecter.automaticReconnectDelaySeconds(), 8)
        XCTAssertEqual(reconnecter.automaticReconnectDelaySeconds(), 20)

        _ = try reconnectInBackground(reconnecter, title: "deploy@example.com")

        XCTAssertEqual(shellBridge.startedConfigs.count, 2)
    }
}

private final class ScriptedRemoteSSHClock {
    private let lock = NSLock()
    private var dates: [Date]

    init(dates: [Date]) {
        self.dates = dates
    }

    func currentDate() -> Date {
        lock.withLock {
            if dates.count > 1 {
                return dates.removeFirst()
            }
            return dates.first ?? Date(timeIntervalSince1970: 0)
        }
    }
}

private final class RecordingTunnelContextBuilder: TunnelLiveSessionContextBuilding {
    private let context: TunnelLiveSessionContext

    init(context: TunnelLiveSessionContext) {
        self.context = context
    }

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        context
    }
}

private final class RecordingProxyAwareTunnelContextBuilder: TunnelLiveSessionContextBuilding {
    private let context: TunnelLiveSessionContext
    private(set) var proxyJumpSelections: [SSHProxyJumpSelection] = []

    init(context: TunnelLiveSessionContext) {
        self.context = context
    }

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        context
    }

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String,
        proxyJumpSelection: SSHProxyJumpSelection,
        proxyJumpSessionResolver: (String) throws -> SessionRecord?
    ) throws -> TunnelLiveSessionContext {
        proxyJumpSelections.append(proxyJumpSelection)
        if case let .session(id) = proxyJumpSelection {
            _ = try proxyJumpSessionResolver(id)
        }
        return context
    }
}

private final class EchoTunnelContextBuilder: TunnelLiveSessionContextBuilding {
    private let template: TunnelLiveSessionContext

    init(template: TunnelLiveSessionContext) {
        self.template = template
    }

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        TunnelLiveSessionContext(
            config: config,
            secret: template.secret,
            expectedFingerprintSHA256: template.expectedFingerprintSHA256
        )
    }
}

private final class AgentFallbackTunnelContextBuilder: TunnelLiveSessionContextBuilding {
    private let template: TunnelLiveSessionContext
    private(set) var requestedConfigs: [SshConnectionConfig] = []

    init(template: TunnelLiveSessionContext) {
        self.template = template
    }

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        requestedConfigs.append(config)
        return TunnelLiveSessionContext(
            config: config,
            secret: config.authMethod == .agent ? .agent : template.secret,
            expectedFingerprintSHA256: template.expectedFingerprintSHA256
        )
    }
}

private final class RecordingLiveShellStarter: LiveShellStarting {
    var startedConfigs: [SshConnectionConfig] = []
    var expectedFingerprints: [String] = []
    var proxyJumpConfigs: [SshConnectionConfig] = []
    var proxyJumpHosts: [String] = []
    private var statuses: [LiveShellStatus]
    private let status: LiveShellStatus?
    private let error: Error?

    init(
        status: LiveShellStatus? = nil,
        statuses: [LiveShellStatus] = [],
        error: Error? = nil
    ) {
        self.status = status
        self.statuses = statuses
        self.error = error
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        if let error { throw error }
        startedConfigs.append(config)
        expectedFingerprints.append(expectedFingerprintSHA256)
        if !statuses.isEmpty {
            return statuses.removeFirst()
        }
        return status ?? LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
    }

    func startLiveSSHShellRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        if let error { throw error }
        proxyJumpConfigs.append(config)
        proxyJumpHosts.append(proxyJump.jumpConfig.host)
        if !statuses.isEmpty {
            return statuses.removeFirst()
        }
        return status ?? LiveShellStatus(runtimeId: "term_live", status: "running", diagnostic: "running")
    }
}

private final class AgentFallbackLiveShellStarter: LiveShellStarting {
    private(set) var startedConfigs: [SshConnectionConfig] = []
    private let firstError: Error

    init(firstError: Error = SshRuntimeError.AuthFailed) {
        self.firstError = firstError
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        startedConfigs.append(config)
        if startedConfigs.count == 1 {
            throw firstError
        }
        return LiveShellStatus(runtimeId: "term_agent", status: "running", diagnostic: "running")
    }

    func startLiveSSHShellRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        try startLiveSSHShellRuntime(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: proxyJump.targetExpectedFingerprintSha256,
            cols: cols,
            rows: rows
        )
    }
}

private final class SlowLiveShellStarter: LiveShellStarting {
    private let status: LiveShellStatus
    private let delay: TimeInterval
    private let lock = NSLock()
    private var startCount = 0

    init(status: LiveShellStatus, delay: TimeInterval) {
        self.status = status
        self.delay = delay
    }

    var startedConfigCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        lock.lock()
        startCount += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: delay)
        return status
    }
}

private final class SequencedDelayLiveShellStarter: LiveShellStarting, LiveShellRuntimeClosing, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(delay: TimeInterval, status: LiveShellStatus)]
    private var closedIDs: [String] = []
    private var startCount = 0

    init(entries: [(delay: TimeInterval, status: LiveShellStatus)]) {
        self.entries = entries
    }

    var closedRuntimeIDs: [String] {
        lock.withLock { closedIDs }
    }

    var startedRuntimeCount: Int {
        lock.withLock { startCount }
    }

    func startLiveSSHShellRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        cols: UInt32,
        rows: UInt32
    ) throws -> LiveShellStatus {
        let entry = lock.withLock {
            startCount += 1
            return entries.isEmpty
                ? (delay: 0, status: LiveShellStatus(runtimeId: "term_fallback", status: "running", diagnostic: "running"))
                : entries.removeFirst()
        }
        Thread.sleep(forTimeInterval: entry.delay)
        return entry.status
    }

    func closeLiveSSHShellRuntime(runtimeID: String) throws {
        lock.withLock {
            closedIDs.append(runtimeID)
        }
    }
}

private final class SequencedTunnelContextBuilder: TunnelLiveSessionContextBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [TunnelLiveSessionContext]

    init(contexts: [TunnelLiveSessionContext]) {
        self.contexts = contexts
    }

    func makeTunnelLiveSessionContext(
        config: SshConnectionConfig,
        databasePath: String
    ) throws -> TunnelLiveSessionContext {
        lock.withLock {
            contexts.isEmpty ? tunnelContext() : contexts.removeFirst()
        }
    }
}

private final class BlockingLiveShellStarter: LiveShellStarting, LiveShellRuntimeClosing {
    private let startRequested = DispatchSemaphore(value: 0)
    private let releaseStartSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let status: LiveShellStatus
    private var closedIDs: [String] = []

    init(status: LiveShellStatus) {
        self.status = status
    }

    var closedRuntimeIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return closedIDs
    }

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
        return status
    }

    func closeLiveSSHShellRuntime(runtimeID: String) throws {
        lock.lock()
        closedIDs.append(runtimeID)
        lock.unlock()
    }
}

private final class RecordingRemoteWorkspaceOpening: RemoteWorkspaceLiveSessionAutomationOpening {
    var openedStatuses: [LiveShellStatus] = []
    var openedTitles: [String] = []
    var reconnecters: [RemoteTerminalReconnecting?] = []
    var liveSessionContexts: [TunnelLiveSessionContext] = []
    var automationPolicies: [SessionAutomationPolicy] = []
    var pendingTitles: [String] = []
    var pendingAutomationPolicies: [SessionAutomationPolicy] = []
    var openedPanes: [RemoteTerminalPaneViewController] = []
    var startupBanners: [String] = []
    var preexistingFailureDiagnostic: String?

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?
    ) {
        openedStatuses.append(status)
        openedTitles.append(title)
        reconnecters.append(reconnecter)
    }

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        liveSessionContext: TunnelLiveSessionContext?
    ) {
        openRemoteShell(status: status, title: title, reconnecter: reconnecter)
        if let liveSessionContext {
            liveSessionContexts.append(liveSessionContext)
        }
    }

    func openRemoteShell(
        status: LiveShellStatus,
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?,
        automationPolicy: SessionAutomationPolicy
    ) {
        openRemoteShell(status: status, title: title, reconnecter: reconnecter, liveSessionContext: liveSessionContext)
        automationPolicies.append(automationPolicy)
        startupBanners.append(
            SSHSessionStartupBanner(
                context: liveSessionContext ?? tunnelContext(),
                title: title,
                runtimeID: status.runtimeId,
                automationPolicy: automationPolicy
            ).rendered()
        )
    }

    func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?,
        automationPolicy: SessionAutomationPolicy
    ) -> RemoteTerminalPaneViewController {
        pendingTitles.append(title)
        pendingAutomationPolicies.append(automationPolicy)
        reconnecters.append(reconnecter)
        let pane = RemoteTerminalPaneViewController(
            runtimeID: "pending_test",
            title: title,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            eventSink: NoopRemoteSSHCoordinatorTerminalEventSink(),
            reconnecter: reconnecter,
            automationPolicy: automationPolicy,
            startsPollingAutomatically: false
        )
        displayPreexistingFailureIfNeeded(on: pane)
        openedPanes.append(pane)
        return pane
    }

    func openConnectingRemoteShell(
        title: String,
        reconnecter: RemoteTerminalReconnecting?,
        connectionKind: RemoteTerminalConnectionKind,
        liveSessionContext: TunnelLiveSessionContext?
    ) -> RemoteTerminalPaneViewController {
        reconnecters.append(reconnecter)
        let pane = RemoteTerminalPaneViewController(
            runtimeID: "pending_test",
            title: title,
            connectionKind: connectionKind,
            liveSessionContext: liveSessionContext,
            eventSink: NoopRemoteSSHCoordinatorTerminalEventSink(),
            reconnecter: reconnecter,
            startsPollingAutomatically: false
        )
        displayPreexistingFailureIfNeeded(on: pane)
        openedPanes.append(pane)
        return pane
    }

    private func displayPreexistingFailureIfNeeded(on pane: RemoteTerminalPaneViewController) {
        guard let preexistingFailureDiagnostic else {
            return
        }
        pane.displayConnectionFailure(preexistingFailureDiagnostic)
    }
}

private final class NoopRemoteSSHCoordinatorTerminalEventSink: TerminalEventSink {
    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {}
    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}
    func terminalDidClose(runtimeID: String) throws {}
}

private final class RecordingRemoteSSHLogStore: StacioLogWriting {
    private let lock = NSLock()
    private var recordedLines: [String] = []

    var lines: [String] {
        lock.withLock { recordedLines }
    }

    func append(level: StacioLogLevel, category: String, message: String, sensitiveValues: [String]) {
        var line = "[\(level.rawValue.uppercased())] [\(category)] \(message)"
        for value in sensitiveValues where value.isEmpty == false {
            line = line.replacingOccurrences(of: value, with: L10n.Diagnostics.redactedCredential)
        }
        lock.withLock {
            recordedLines.append(line)
        }
    }
}

private func tunnelContext(
    connectTimeoutMs: UInt32 = 10_000,
    proxyJump: SshProxyJumpRuntimeConfig? = nil
) -> TunnelLiveSessionContext {
    TunnelLiveSessionContext(
        config: SshConnectionConfig(
            host: "example.com",
            port: 22,
            username: "deploy",
            authMethod: .password(credentialRef: "password-ref"),
            connectTimeoutMs: connectTimeoutMs
        ),
        secret: .password(value: "super-secret"),
        expectedFingerprintSHA256: "SHA256:test",
        proxyJump: proxyJump
    )
}

private func proxyJumpRuntimeConfig() -> SshProxyJumpRuntimeConfig {
    SshProxyJumpRuntimeConfig(
        jumpConfig: SshConnectionConfig(
            host: "bastion.example.com",
            port: 2222,
            username: "ops",
            authMethod: .password(credentialRef: "jump-password-ref"),
            connectTimeoutMs: 10_000
        ),
        jumpSecret: .password(value: "jump-secret"),
        jumpExpectedFingerprintSha256: "SHA256:jump",
        targetExpectedFingerprintSha256: "SHA256:test"
    )
}

private func savedProxyJumpSession(id: String) -> SessionRecord {
    SessionRecord(
        id: id,
        folderId: nil,
        name: "Bastion",
        protocol: "ssh",
        host: "bastion.example.com",
        port: 2222,
        username: "ops",
        privateKeyPath: nil,
        credentialId: "jump-password-ref",
        tags: [],
        lastOpenedAt: nil
    )
}
