import AppKit
import Foundation
import StacioAgentBridge
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class AIAssistantLocalRuntimeIntegrationTests: XCTestCase {
    func testV2InspectorSelectsSendsAndStopsLocalCodexFromSinglePrimaryAction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalRuntimePanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workingDirectory = directory.resolvingSymlinksInPath().path
        let codex = makeLocalRuntimeConfiguration(
            tool: .codex,
            executablePath: "/tools/codex",
            workingDirectory: workingDirectory
        )
        let claude = makeLocalRuntimeConfiguration(
            tool: .claude,
            executablePath: "/tools/claude",
            workingDirectory: workingDirectory
        )
        let resolver = LocalRuntimePanelResolver(configurations: [
            .codex: codex,
            .claude: claude
        ])
        let launcher = LocalRuntimePanelLauncher()
        let authorizer = LocalRuntimePanelLaunchAuthorizer()
        let context = AITerminalContext(
            runtimeID: "term-local-agent",
            connectionGeneration: 4,
            title: "ops@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let databasePath = directory.appendingPathComponent("conversation.sqlite3").path
        let runtimeFactory = makeRuntimeFactory(
            databasePath: databasePath,
            context: context
        )
        let defaults = UserDefaults(
            suiteName: "StacioLocalRuntimePanelSettings-\(UUID().uuidString)"
        )!
        let settingsStore = AppSettingsStore(defaults: defaults)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: LocalRuntimePanelProvider(),
                executionCoordinator: LocalRuntimePanelCommandExecutor(),
                settingsStore: settingsStore
            ),
            contextProvider: { runtimeID in
                runtimeID == nil || runtimeID == context.runtimeID ? context : nil
            },
            settingsStore: settingsStore,
            conversationRuntimeFactory: runtimeFactory,
            conversationCatalogLoader: { [] },
            localAgentToolResolver: resolver,
            localAgentProcessLauncherFactory: { launcher },
            localAgentRuntimeLaunchAuthorizerProvider: { authorizer },
            localAgentSettingsOpener: {}
        )

        panel.loadView()
        XCTAssertTrue(waitUntil { panel.conversationRuntimeReadyForTesting })
        XCTAssertEqual(
            panel.localAgentRuntimeOptionTitlesForTesting,
            ["Local Agent · \(codex.displayName)", "Local Agent · \(claude.displayName)"]
        )
        XCTAssertTrue(panel.composerModelPickerModelTitlesForTesting.contains(codex.displayName))
        XCTAssertTrue(panel.composerModelPickerModelTitlesForTesting.contains(claude.displayName))

        XCTAssertTrue(
            panel.selectLocalAgentRuntimeForTesting(.codex),
            panel.conversationStateForTesting
        )
        XCTAssertEqual(panel.localAgentTerminalStateForTesting, .ready(.codex))
        let selectionStartState = panel.conversationStateForTesting

        XCTAssertTrue(waitUntil {
            panel.conversationRuntimeSelectionForTesting?.localAgentConfigurationID
                == codex.configurationID
        }, "start: \(selectionStartState); end: \(panel.conversationStateForTesting)")
        XCTAssertEqual(panel.localAgentTerminalStateForTesting, .ready(.codex))
        XCTAssertEqual(panel.composerModelTitleForTesting, "Local Agent · \(codex.displayName)")
        XCTAssertEqual(launcher.startCount, 0, "Selecting a Runtime must not launch its CLI")

        panel.setQuestionForTesting("检查当前服务状态")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            launcher.startCount == 1
                && panel.localAgentTerminalStateForTesting?.isRunning == true
        })
        XCTAssertEqual(launcher.sentTexts, ["检查当前服务状态\n"])
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, "停止当前排查任务")
        XCTAssertTrue(panel.generalStopEnabledForTesting)
        XCTAssertTrue(panel.conversationTurnBindingControlsFrozenForTesting)
        XCTAssertFalse(
            panel.view.allDescendantButtons.contains {
                $0.toolTip == "停止 Local Agent 终端"
            },
            "The Composer primary action is the only stop control"
        )

        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            launcher.terminated
                && panel.localAgentTerminalStateForTesting?.preventsRuntimeChange == false
                && panel.primaryActionAccessibilityLabelForTesting == "发送排查问题"
        })
        XCTAssertTrue(panel.conversationRuntimeIdleForTesting)
    }

    func testV2RuntimePickerExplainsHowToConfigureLocalAgentsWhenNoneAreReady() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalRuntimeSetup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = AITerminalContext(
            runtimeID: "term-local-agent-setup",
            title: "ops@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let settingsStore = AppSettingsStore(defaults: UserDefaults(
            suiteName: "StacioLocalRuntimeSetupSettings-\(UUID().uuidString)"
        )!)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: LocalRuntimePanelProvider(),
                executionCoordinator: LocalRuntimePanelCommandExecutor(),
                settingsStore: settingsStore
            ),
            contextProvider: { _ in context },
            settingsStore: settingsStore,
            conversationRuntimeFactory: makeRuntimeFactory(
                databasePath: directory.appendingPathComponent("conversation.sqlite3").path,
                context: context
            ),
            conversationCatalogLoader: { [] },
            localAgentToolResolver: LocalRuntimePanelResolver(configurations: [:]),
            localAgentSettingsOpener: {}
        )

        panel.loadView()
        XCTAssertTrue(waitUntil { panel.conversationRuntimeReadyForTesting })
        XCTAssertTrue(
            panel.composerModelPickerModelTitlesForTesting.contains("配置本地 Coding Agent…")
        )
    }

    func testV2InspectorKeepsExistingPATHCodexThroughExplicitCompatibilityEntry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLegacyLocalRuntimePanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = AITerminalContext(
            runtimeID: "term-legacy-local-agent",
            connectionGeneration: 5,
            title: "ops@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let launcher = LocalRuntimePanelLauncher()
        let settingsStore = AppSettingsStore(defaults: UserDefaults(
            suiteName: "StacioLegacyLocalRuntimeSettings-\(UUID().uuidString)"
        )!)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: LocalRuntimePanelProvider(),
                executionCoordinator: LocalRuntimePanelCommandExecutor(),
                settingsStore: settingsStore
            ),
            contextProvider: { runtimeID in
                runtimeID == nil || runtimeID == context.runtimeID ? context : nil
            },
            settingsStore: settingsStore,
            conversationRuntimeFactory: makeRuntimeFactory(
                databasePath: directory.appendingPathComponent("conversation.sqlite3").path,
                context: context
            ),
            conversationCatalogLoader: { [] },
            localAgentToolResolver: LegacyRuntimePanelResolver(
                paths: [.codex: "/tools/codex"]
            ),
            localAgentProcessLauncherFactory: { launcher },
            localAgentSettingsOpener: {}
        )

        panel.loadView()
        let runtimeReady = await waitUntilAsync { panel.conversationRuntimeReadyForTesting }
        XCTAssertTrue(runtimeReady, panel.conversationStateForTesting)
        XCTAssertEqual(
            panel.legacyLocalAgentRuntimeOptionTitlesForTesting,
            ["Codex · 兼容本地 CLI"]
        )
        XCTAssertTrue(panel.selectLegacyLocalAgentRuntimeForTesting(.codex))
        XCTAssertEqual(panel.composerModelTitleForTesting, "Local Agent · Codex")
        XCTAssertFalse(panel.composerModelPickerShowsReasoningForTesting)

        panel.setQuestionForTesting("在兼容进程启动前取消")
        panel.performAskForTesting()
        panel.performAskForTesting()
        let cancelledBeforeLaunch = await waitUntilAsync {
            panel.primaryActionAccessibilityLabelForTesting == "发送排查问题"
        }
        XCTAssertTrue(cancelledBeforeLaunch, panel.conversationStateForTesting)
        XCTAssertEqual(launcher.startCount, 0, "A latched Stop must prevent a late compatibility launch")

        panel.setQuestionForTesting("检查旧版 Codex 兼容链路")
        panel.performAskForTesting()
        let started = await waitUntilAsync {
            launcher.startCount == 1
                && panel.localAgentTerminalStateForTesting?.isRunning == true
        }
        XCTAssertTrue(started, panel.conversationStateForTesting)
        XCTAssertEqual(launcher.sentTexts, ["检查旧版 Codex 兼容链路\n"])
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, "停止当前排查任务")

        panel.performAskForTesting()
        let stopped = await waitUntilAsync {
            launcher.terminated
                && panel.primaryActionAccessibilityLabelForTesting == "发送排查问题"
        }
        XCTAssertTrue(stopped, panel.conversationStateForTesting)
    }

    func testV2InspectorDeliversLocalAgentAfterCapacityWait() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioLocalRuntimeCapacity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workingDirectory = directory.resolvingSymlinksInPath().path
        let codex = makeLocalRuntimeConfiguration(
            tool: .codex,
            executablePath: "/tools/codex",
            workingDirectory: workingDirectory
        )
        let resolver = LocalRuntimePanelResolver(
            configurations: [.codex: codex],
            legacyPaths: [.claude: "/tools/claude"]
        )
        let launcher = LocalRuntimePanelLauncher()
        let authorizer = LocalRuntimePanelLaunchAuthorizer()
        let context = AITerminalContext(
            runtimeID: "term-local-agent-capacity",
            connectionGeneration: 7,
            title: "ops@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let scheduler = ProductionAgentExecutionScheduler(capacity: 1)
        let blockingRequest = try await scheduler.enqueue(
            sessionID: "capacity-blocker",
            turnID: "turn-blocker",
            attemptID: "attempt-blocker",
            config: SchedulerConfig(capacity: 1, waitTimeout: 30)
        )
        guard case .granted(let blockingLease) = await scheduler.waitForResolution(
            requestID: blockingRequest.requestID
        ) else {
            return XCTFail("test scheduler must occupy its only slot")
        }
        try await scheduler.activate(blockingLease)

        let defaults = UserDefaults(
            suiteName: "StacioLocalRuntimeCapacitySettings-\(UUID().uuidString)"
        )!
        let settingsStore = AppSettingsStore(defaults: defaults)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: LocalRuntimePanelProvider(),
                executionCoordinator: LocalRuntimePanelCommandExecutor(),
                settingsStore: settingsStore
            ),
            contextProvider: { runtimeID in
                runtimeID == nil || runtimeID == context.runtimeID ? context : nil
            },
            settingsStore: settingsStore,
            conversationRuntimeFactory: makeRuntimeFactory(
                databasePath: directory.appendingPathComponent("conversation.sqlite3").path,
                context: context,
                admissionCoordinator: scheduler,
                runtimeSettingsSnapshot: try makeSingleCapacityRuntimeSettings()
            ),
            conversationCatalogLoader: { [] },
            localAgentToolResolver: resolver,
            localAgentProcessLauncherFactory: { launcher },
            localAgentRuntimeLaunchAuthorizerProvider: { authorizer },
            localAgentSettingsOpener: {}
        )

        panel.loadView()
        let runtimeReady = await waitUntilAsync { panel.conversationRuntimeReadyForTesting }
        XCTAssertTrue(runtimeReady, panel.conversationStateForTesting)
        XCTAssertTrue(panel.selectLocalAgentRuntimeForTesting(.codex), panel.conversationStateForTesting)
        let selectionReady = await waitUntilAsync {
            panel.conversationRuntimeSelectionForTesting?.localAgentConfigurationID
                == codex.configurationID
        }
        XCTAssertTrue(selectionReady, panel.conversationStateForTesting)
        panel.setQuestionForTesting("等待容量后检查服务")
        panel.performAskForTesting()

        let submissionStarted = await waitUntilAsync {
            panel.primaryActionAccessibilityLabelForTesting == "停止当前排查任务"
        }
        XCTAssertTrue(submissionStarted)
        XCTAssertEqual(launcher.startCount, 0, "capacity wait must not launch the CLI early")
        XCTAssertFalse(
            panel.selectLegacyLocalAgentRuntimeForTesting(.claude),
            "A stale Runtime picker action must be rejected while the durable Turn is active"
        )
        XCTAssertEqual(
            panel.conversationRuntimeSelectionForTesting?.localAgentConfigurationID,
            codex.configurationID
        )

        _ = try await scheduler.release(blockingLease)
        let deliveryStarted = await waitUntilAsync {
            launcher.startCount == 1
                && panel.localAgentTerminalStateForTesting?.isRunning == true
        }
        XCTAssertTrue(deliveryStarted)
        XCTAssertEqual(launcher.sentTexts, ["等待容量后检查服务\n"])

        panel.performAskForTesting()
        let stopped = await waitUntilAsync {
            launcher.terminated
                && panel.primaryActionAccessibilityLabelForTesting == "发送排查问题"
        }
        XCTAssertTrue(stopped)
    }

    func testV2InspectorStructuredLocalAgentUsesTranscriptAndSinglePrimaryAction() async throws {
        let fixture = try StructuredPanelAgentFixture()
        defer { fixture.cleanup() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioStructuredRuntimePanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = AITerminalContext(
            runtimeID: "term-structured-local-agent",
            connectionGeneration: 8,
            title: "ops@example.com",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let configuration = fixture.configuration
        let resolver = LocalRuntimePanelResolver(configurations: [.codex: configuration])
        let settingsStore = AppSettingsStore(defaults: UserDefaults(
            suiteName: "StacioStructuredRuntimePanelSettings-\(UUID().uuidString)"
        )!)
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: LocalRuntimePanelProvider(),
                executionCoordinator: LocalRuntimePanelCommandExecutor(),
                settingsStore: settingsStore
            ),
            contextProvider: { runtimeID in
                runtimeID == nil || runtimeID == context.runtimeID ? context : nil
            },
            settingsStore: settingsStore,
            conversationRuntimeFactory: makeRuntimeFactory(
                databasePath: directory.appendingPathComponent("conversation.sqlite3").path,
                context: context
            ),
            conversationCatalogLoader: { [] },
            localAgentToolResolver: resolver,
            localAgentSettingsOpener: {}
        )

        panel.loadView()
        let runtimeReady = await waitUntilAsync { panel.conversationRuntimeReadyForTesting }
        XCTAssertTrue(runtimeReady, panel.conversationStateForTesting)
        XCTAssertTrue(panel.selectLocalAgentRuntimeForTesting(.codex))
        let selectionReady = await waitUntilAsync {
            panel.conversationRuntimeSelectionForTesting?.localAgentConfigurationID
                == configuration.configurationID
        }
        XCTAssertTrue(selectionReady, panel.conversationStateForTesting)
        XCTAssertEqual(
            panel.localAgentTerminalStateForTesting,
            .hidden,
            "结构化 Local Agent 不应在 Inspector 中占用旧 PTY 终端区域"
        )

        panel.setQuestionForTesting("检查当前服务状态")
        panel.performAskForTesting()
        let started = await waitUntilAsync {
            panel.primaryActionAccessibilityLabelForTesting == "停止当前排查任务"
        }
        XCTAssertTrue(started, panel.conversationStateForTesting)
        XCTAssertFalse(
            panel.view.allDescendantButtons.contains { $0.toolTip == "停止 Local Agent 终端" },
            "结构化 Local Agent 仍只能使用 Composer 的单一 Stop 动作"
        )

        let completed = await waitUntilAsync {
            panel.conversationRuntimeIdleForTesting
                && panel.transcriptTextForTesting.contains("服务状态正常")
        }
        XCTAssertTrue(completed, panel.conversationStateForTesting)
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, "发送排查问题")
        XCTAssertFalse(panel.localAgentTerminalStateForTesting?.isRunning == true)
    }

    private func makeRuntimeFactory(
        databasePath: String,
        context: AITerminalContext,
        admissionCoordinator: AgentExecutionAdmissionCoordinating? = nil,
        runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot? = nil
    ) -> InspectorConversationRuntimeFactory {
        { sessionID, _, _ in
            let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x63, count: 32))
            let repository = try ConversationRepositoryV2(
                conversationID: sessionID,
                databasePath: databasePath,
                encryption: encryption
            )
            let state = ConversationV2StorageFactory.makeInitialSessionState(
                sessionID: sessionID,
                memoryScope: context.historyScopeID,
                initialTargetContext: context
            )
            let actor = ConversationSessionActor(
                sessionID: sessionID,
                initialState: state,
                store: repository,
                sealing: ConversationEncryptionSealingAdapter(
                    encryption: encryption,
                    conversationID: sessionID
                )
            )
            let bridge = SessionRuntimeBridge(
                actor: actor,
                sessionID: sessionID,
                initialState: state,
                terminalContextProvider: { context },
                targetContextResolver: { runtimeID in
                    runtimeID == nil || runtimeID == context.runtimeID ? context : nil
                },
                runtimeSettingsProvider: {
                    if let runtimeSettingsSnapshot {
                        return runtimeSettingsSnapshot
                    }
                    return try AssistantRuntimeSettingsSnapshot.resolve(from: nil)
                },
                admissionCoordinator: admissionCoordinator,
                providerResolver: { nil },
                initialTargetContext: context,
                restorePending: false
            )
            return InspectorConversationRuntime(
                sessionID: sessionID,
                bridge: bridge,
                repository: repository,
                initialExecutionChoice: .realTerminal
            )
        }
    }

    private func makeSingleCapacityRuntimeSettings() throws -> AssistantRuntimeSettingsSnapshot {
        let defaults = try AssistantRuntimeSettingsSnapshot.resolve(from: nil)
        var values = defaults.valuesByID
        values["assistant.execution.maxParallelAttempts"] = .int(1)
        return AssistantRuntimeSettingsSnapshot(
            registryRevision: defaults.registryRevision,
            valuesByID: values
        )
    }

    private func makeLocalRuntimeConfiguration(
        tool: LocalAgentTool,
        executablePath: String,
        workingDirectory: String
    ) -> LocalAgentPassthroughConfiguration {
        let environment = [
            "PATH=/tools",
            "STACIO_LOCAL_AGENT=\(tool.catalogRawIdentity)"
        ].sorted()
        return LocalAgentPassthroughConfiguration(
            configurationID: "local-panel-\(tool.rawValue)",
            configurationRevision: 1,
            catalogID: "local-agent.\(tool.rawValue)",
            catalogSetRevision: 1,
            descriptorRevision: 1,
            tool: tool,
            displayName: tool == .codex ? "Codex" : "Claude Code",
            executablePath: executablePath,
            executableIdentityDigest: "digest-\(tool.rawValue)",
            executableReferenceConfirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            executionProfileID: "terminal-passthrough-\(tool.rawValue)",
            executionProfileRevision: 1,
            authenticationState: .authenticated,
            authenticationEvidenceRevision: "auth-1",
            cliAuthenticationScopeDigest: "scope-\(tool.rawValue)",
            cliLoginIdentityDigest: "login-\(tool.rawValue)",
            environmentDigest: LocalAgentConfigurationIntegrity.environmentDigest(environment),
            launchEnvironment: environment,
            executableName: URL(fileURLWithPath: executablePath).lastPathComponent,
            workingDirectoryMode: .userSelectedLocalDirectory,
            workingDirectoryReference: workingDirectory,
            supportLevel: .experimental,
            explicitlyEnabled: true
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 3,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct LocalRuntimePanelResolver: LocalAgentToolResolving {
    let configurations: [LocalAgentTool: LocalAgentPassthroughConfiguration]
    let legacyPaths: [LocalAgentTool: String]

    init(
        configurations: [LocalAgentTool: LocalAgentPassthroughConfiguration],
        legacyPaths: [LocalAgentTool: String] = [:]
    ) {
        self.configurations = configurations
        self.legacyPaths = legacyPaths
    }

    func executablePath(for tool: LocalAgentTool) -> String? {
        configurations[tool]?.executablePath
    }

    func passthroughConfiguration(for tool: LocalAgentTool) -> LocalAgentPassthroughConfiguration? {
        configurations[tool]
    }

    func legacyExecutablePath(for tool: LocalAgentTool) -> String? {
        configurations[tool]?.executablePath ?? legacyPaths[tool]
    }
}

private struct StructuredPanelAgentFixture {
    let root: URL
    let executable: URL
    let configuration: LocalAgentPassthroughConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-structured-panel-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        read init_line
        init_id=$(printf '%s' "$init_line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '{"jsonrpc":"2.0","id":"%s","result":{}}\\n' "$init_id"
        read initialized_line
        read thread_line
        thread_id=$(printf '%s' "$thread_line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"thread":{"id":"thread-1"}}}\\n' "$thread_id"
        read turn_line
        turn_id=$(printf '%s' "$turn_line" | sed -E 's/.*"id":"([^"]+)".*/\\1/')
        printf '{"jsonrpc":"2.0","id":"%s","result":{"turn":{"id":"turn-1"}}}\\n' "$turn_id"
        sleep 0.2
        printf '%s\\n' '{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"delta":"服务状态正常"}}'
        printf '%s\\n' '{"jsonrpc":"2.0","method":"turn/completed","params":{"turn":{"id":"turn-1","status":"completed"}}}'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        let environment = ["LANG=C", "PATH=/usr/bin:/bin"].sorted()
        configuration = LocalAgentPassthroughConfiguration(
            configurationID: "structured-panel-codex",
            configurationRevision: 1,
            catalogID: "local-agent.codex",
            catalogSetRevision: 1,
            descriptorRevision: 1,
            tool: .codex,
            displayName: "Codex",
            executablePath: executable.path,
            executableIdentityDigest: "fixture-codex",
            executableReferenceConfirmedAt: Date(),
            lastVerifiedAt: Date(),
            executionProfileID: "managed-rpc",
            executionProfileRevision: 1,
            structuredProtocol: .rpc,
            authenticationState: .authenticated,
            authenticationEvidenceRevision: "auth-1",
            cliAuthenticationScopeDigest: "scope-1",
            cliLoginIdentityDigest: "identity-1",
            environmentDigest: LocalAgentConfigurationIntegrity.environmentDigest(environment),
            launchEnvironment: environment,
            executableName: "codex",
            supportLevel: .experimental,
            explicitlyEnabled: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LegacyRuntimePanelResolver: LocalAgentToolResolving {
    let paths: [LocalAgentTool: String]

    func executablePath(for tool: LocalAgentTool) -> String? {
        paths[tool]
    }
}

private final class LocalRuntimePanelLauncher: LocalTerminalProcessLaunching {
    private(set) var startCount = 0
    private(set) var sentTexts: [String] = []
    private(set) var terminated = false
    private var running = false

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool { running }
    func managedProcessGroupID(_ terminalView: LocalProcessTerminalView) -> Int32? {
        running ? 9_101 : nil
    }
    func managedProcessIdentifier(_ terminalView: LocalProcessTerminalView) -> Int32? {
        running ? 9_101 : nil
    }
    func managedProcessTrustedStartTime(_ terminalView: LocalProcessTerminalView) -> Date? {
        running ? Date(timeIntervalSince1970: 1_700_000_003) : nil
    }
    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        startCount += 1
        running = true
    }
    func terminate(_ terminalView: LocalProcessTerminalView) {
        terminated = true
        running = false
    }
    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {
        sentTexts.append(String(decoding: bytes, as: UTF8.self))
    }
}

private final class LocalRuntimePanelLaunchAuthorizer: LocalAgentRuntimeLaunchAuthorizing {
    private let usage = LocalAgentRuntimeUsageRegistry()

    func acquireUsage(
        configurationID: String,
        expectedConfigurationRevision: Int64
    ) throws -> LocalAgentRuntimeUsageLease {
        guard let lease = usage.acquireUsage(configurationID: configurationID) else {
            throw LocalAgentRuntimeLaunchAuthorizationError.unavailable
        }
        return lease
    }
}

private struct LocalRuntimePanelProvider: AIAssistantProviding {
    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        AIAssistantResponse(message: "", proposedCommand: nil)
    }
}

@MainActor
private final class LocalRuntimePanelCommandExecutor: AgentCommandExecuting {
    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] { [] }
}

private extension NSView {
    var allDescendantButtons: [NSButton] {
        subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? []
                + child.allDescendantButtons
        }
    }
}
