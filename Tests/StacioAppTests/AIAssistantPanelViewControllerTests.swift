import AppKit
import StacioAgentBridge
import StacioCoreBindings
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class AIAssistantPanelViewControllerTests: XCTestCase {
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

    func testOpenAICompatibleProviderPostsChatCompletionAndParsesCommandProposal() throws {
        let transport = RecordingAIAssistantHTTPTransport(
            responseBody: """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"message\\":\\"建议先看系统负载。\\",\\"commands\\":[{\\"command\\":\\"uptime\\",\\"explanation\\":\\"查看负载均值\\"}]}"
                  }
                }
              ]
            }
            """
        )
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try provider.respond(
            to: AIAssistantRequest(
                question: "这台机器卡吗？",
                context: AITerminalContext(
                    runtimeID: "term_ssh",
                    title: "root@centos7",
                    currentDirectory: "/srv/app",
                    recentTranscript: "load average: 3.14"
                )
            )
        )

        XCTAssertEqual(response.message, "建议先看系统负载。")
        XCTAssertEqual(response.commandProposals.map(\.command), ["uptime"])
        XCTAssertEqual(response.commandProposals.map(\.explanation), ["查看负载均值"])
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-secret")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("ops-model"))
        XCTAssertTrue(body.contains("load average: 3.14"))
        XCTAssertFalse(body.contains("sk-test-secret"))
    }

    func testSSEParserHandlesSplitDataLinesDoneAndMalformedEvents() throws {
        var parser = OpenAICompatibleSSEParser()

        let first = parser.consume(Data(#"data: {"choices":[{"delta":{"content":"Hel"#.utf8))
        let second = parser.consume(Data((#"lo"}}]}"# + "\n").utf8))
        let malformed = parser.consume(Data("data: {not-json}\n".utf8))
        let third = parser.consume(Data((#"data: {"choices":[{"delta":{"content":" world"}}]}"# + "\n\n").utf8))
        let done = parser.consume(Data("data: [DONE]\n".utf8))

        XCTAssertEqual(first, [])
        XCTAssertEqual(second.map(\.contentDelta), ["Hello"])
        XCTAssertEqual(malformed, [])
        XCTAssertEqual(third.map(\.contentDelta), [" world"])
        XCTAssertEqual(done.map(\.isDone), [true])
        XCTAssertTrue(parser.isDone)
    }

    func testOpenAICompatibleProviderStreamsVisibleMessageFromSplitSSEAndSendsStreamTrue() async throws {
        let transport = StreamingAIAssistantHTTPTransport(chunks: [
            Data(chatStreamDataLine(content: #"{"message":"建议"#).utf8),
            Data(chatStreamDataLine(content: #"先看负载。","commands":[{"command":"uptime","explanation":"查看负载"}]}"#).utf8),
            Data("data: [DONE]\n\n".utf8)
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )
        var partials: [String] = []

        let response = try await provider.respondStreaming(
            to: makeAIRequest(),
            onPartial: { partials.append($0) }
        )

        XCTAssertEqual(partials.joined(), "建议先看负载。")
        XCTAssertEqual(response.message, "建议先看负载。")
        XCTAssertEqual(response.commandProposals.map(\.command), ["uptime"])
        XCTAssertEqual(transport.streamRequests.count, 1)
        let requestBody = try XCTUnwrap(transport.streamRequests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testOpenAICompatibleProviderFallsBackToNonStreamingWhenStreamUnsupported() async throws {
        let transport = UnsupportedStreamingAIAssistantHTTPTransport(
            responseBody: chatCompletionBody(message: "非流式降级可用。")
        )
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try await provider.respondStreaming(to: makeAIRequest(), onPartial: { _ in })

        XCTAssertEqual(response.message, "非流式降级可用。")
        XCTAssertEqual(transport.streamRequests.count, 1)
        XCTAssertEqual(transport.requests.count, 1)
        let fallbackBody = try XCTUnwrap(transport.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: fallbackBody) as? [String: Any])
        XCTAssertNil(json["stream"])
    }

    func testLocalAgentToolResolverFindsKnownAndPathExecutables() {
        let executablePaths: Set<String> = [
            "/Users/test/.hermes/node/bin/codex",
            "/Users/test/.opencode/bin/opencode",
            "/custom/bin/claude",
            "/Users/test/.local/bin/mimo",
            "/opt/homebrew/bin/zcode",
            "/usr/local/bin/qwen"
        ]
        let resolver = LocalAgentToolResolver(
            environment: ["PATH": "/custom/bin:/ignored/bin"],
            homeDirectory: "/Users/test",
            isExecutable: { executablePaths.contains($0) }
        )

        XCTAssertEqual(resolver.executablePath(for: .codex), "/Users/test/.hermes/node/bin/codex")
        XCTAssertEqual(resolver.executablePath(for: .claude), "/custom/bin/claude")
        XCTAssertEqual(resolver.executablePath(for: .opencode), "/Users/test/.opencode/bin/opencode")
        XCTAssertEqual(resolver.executablePath(for: .mimoCode), "/Users/test/.local/bin/mimo")
        XCTAssertEqual(resolver.executablePath(for: .zcode), "/opt/homebrew/bin/zcode")
        XCTAssertEqual(resolver.executablePath(for: .qwenCode), "/usr/local/bin/qwen")
    }

    func testLocalAgentSessionStartsNativeToolWithCurrentDirectoryAndEnvironment() {
        let launcher = RecordingLocalAgentProcessLauncher()
        let controller = LocalAgentSessionViewController(
            tool: .codex,
            resolver: StaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"]),
            processLauncher: launcher,
            currentDirectoryProvider: { "/srv/app" },
            environmentProvider: { ["PATH": "/tools"] }
        )

        controller.loadView()
        controller.startIfNeeded()

        XCTAssertEqual(launcher.startedExecutable, "/tools/codex")
        XCTAssertEqual(launcher.startedArgs, [])
        XCTAssertEqual(launcher.startedExecName, "codex")
        XCTAssertEqual(launcher.startedCurrentDirectory, "/srv/app")
        XCTAssertEqual(launcher.startedEnvironmentDictionary["STACIO_LOCAL_AGENT"], "codex")
        XCTAssertEqual(launcher.startedEnvironmentDictionary["TERM"], "xterm-256color")
        XCTAssertEqual(launcher.startedEnvironmentDictionary["COLORTERM"], "truecolor")
        XCTAssertTrue(launcher.startedEnvironmentDictionary["PATH"]?.hasPrefix("/tools:") == true)
        XCTAssertTrue(launcher.startedEnvironmentDictionary["PATH"]?.contains("/.hermes/node/bin") == true)
        XCTAssertEqual(controller.launchState, .running("/tools/codex"))
    }

    func testLocalAgentSessionCanRestartAfterProcessTerminates() {
        let launcher = RecordingLocalAgentProcessLauncher()
        let controller = LocalAgentSessionViewController(
            tool: .codex,
            resolver: StaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"]),
            processLauncher: launcher,
            currentDirectoryProvider: { "/srv/app" },
            environmentProvider: { ["PATH": "/tools"] }
        )

        controller.loadView()
        controller.startIfNeeded()
        controller.processTerminated(source: controller.terminalView, exitCode: 0)
        launcher.running = false
        controller.startIfNeeded()

        XCTAssertEqual(launcher.startCount, 2)
        XCTAssertEqual(controller.launchState, .running("/tools/codex"))
    }

    func testLocalAgentSessionRetriesLaunchAfterMissingExecutableIsInstalled() {
        let launcher = RecordingLocalAgentProcessLauncher()
        let resolver = MutableLocalAgentToolResolver(paths: [:])
        let controller = LocalAgentSessionViewController(
            tool: .codex,
            resolver: resolver,
            processLauncher: launcher,
            currentDirectoryProvider: { "/srv/app" },
            environmentProvider: { ["PATH": "/tools"] }
        )

        controller.loadView()
        controller.startIfNeeded()
        resolver.paths[.codex] = "/tools/codex"
        controller.startIfNeeded()

        XCTAssertEqual(launcher.startCount, 1)
        XCTAssertEqual(controller.launchState, .running("/tools/codex"))
    }

    func testLocalAgentSessionInstallsStacioRemoteBridgeToolsAndEnvironment() throws {
        let launcher = RecordingLocalAgentProcessLauncher()
        let toolsDirectory = NSTemporaryDirectory()
            + "stacio-agent-tools-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: toolsDirectory)
        }
        let targetFile = "\(toolsDirectory)/target"
        let workspaceDirectory = "\(toolsDirectory)/workspace"
        let bridgeContext = LocalAgentBridgeContext(
            socketPath: "/tmp/stacio-agent.sock",
            targetRuntimeID: "term_remote",
            targetTitle: "root@192.168.1.201",
            remoteCurrentDirectory: "/srv/app",
            cliExecutablePath: "/tools/stacio",
            toolsDirectory: toolsDirectory,
            workspaceDirectory: workspaceDirectory,
            targetFilePath: targetFile
        )
        let controller = LocalAgentSessionViewController(
            tool: .codex,
            resolver: StaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"]),
            processLauncher: launcher,
            currentDirectoryProvider: { "/srv/app" },
            bridgeContextProvider: { bridgeContext },
            environmentProvider: { ["PATH": "/usr/bin", "HOME": "/Users/test"] }
        )

        controller.loadView()
        controller.startIfNeeded()

        let environment = launcher.startedEnvironmentDictionary
        XCTAssertEqual(environment["STACIO_AGENT_SOCKET"], "/tmp/stacio-agent.sock")
        XCTAssertEqual(environment["STACIO_AGENT_TARGET_RUNTIME_ID"], "term_remote")
        XCTAssertEqual(environment["STACIO_AGENT_TARGET_TITLE"], "root@192.168.1.201")
        XCTAssertEqual(environment["STACIO_REMOTE_CURRENT_DIRECTORY"], "/srv/app")
        XCTAssertEqual(environment["STACIO_AGENT_TARGET_FILE"], targetFile)
        XCTAssertEqual(environment["STACIO_CLI"], "/tools/stacio")
        XCTAssertEqual(environment["STACIO_REMOTE_COMMAND"], #"stacio-remote "uptime""#)
        XCTAssertTrue(environment["PATH"]?.hasPrefix("\(toolsDirectory):/tools:") == true)
        XCTAssertEqual(launcher.startedCurrentDirectory, workspaceDirectory)
        XCTAssertEqual(controller.activeBridgeContext, bridgeContext)
        XCTAssertNil(controller.bridgeInstallError)

        let remoteTool = "\(toolsDirectory)/stacio-remote"
        let sessionsTool = "\(toolsDirectory)/stacio-sessions"
        let agentTool = "\(toolsDirectory)/stacio-agent"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: remoteTool))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: sessionsTool))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agentTool))
        let remoteScript = try String(contentsOfFile: remoteTool, encoding: .utf8)
        XCTAssertTrue(remoteScript.contains("agent run"))
        XCTAssertTrue(remoteScript.contains("--runtime"))
        XCTAssertTrue(remoteScript.contains("STACIO_AGENT_TARGET_FILE"))
        XCTAssertEqual(
            try String(contentsOfFile: targetFile, encoding: .utf8),
            "term_remote\n"
        )
        let agentInstructions = try String(
            contentsOfFile: "\(workspaceDirectory)/AGENTS.md",
            encoding: .utf8
        )
        XCTAssertTrue(agentInstructions.contains(#"stacio-remote "<command>""#))
        XCTAssertTrue(agentInstructions.contains("/srv/app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspaceDirectory)/CLAUDE.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspaceDirectory)/README.md"))
    }

    func testLocalAgentBridgeTargetFileRefreshesWhenSelectedRuntimeChanges() throws {
        let launcher = RecordingLocalAgentProcessLauncher()
        let toolsDirectory = NSTemporaryDirectory()
            + "stacio-agent-tools-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: toolsDirectory)
        }
        let targetFile = "\(toolsDirectory)/target"
        var runtimeID = "term_a"
        let controller = LocalAgentSessionViewController(
            tool: .codex,
            resolver: StaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"]),
            processLauncher: launcher,
            bridgeContextProvider: {
                LocalAgentBridgeContext(
                    socketPath: "/tmp/stacio-agent.sock",
                    targetRuntimeID: runtimeID,
                    targetTitle: "selected",
                    cliExecutablePath: "/tools/stacio",
                    toolsDirectory: toolsDirectory,
                    targetFilePath: targetFile
                )
            },
            environmentProvider: { ["PATH": "/usr/bin", "HOME": "/Users/test"] }
        )

        controller.loadView()
        controller.startIfNeeded()
        XCTAssertEqual(
            try String(contentsOfFile: targetFile, encoding: .utf8),
            "term_a\n"
        )

        runtimeID = "term_b"
        controller.refreshBridgeContext()

        XCTAssertEqual(
            try String(contentsOfFile: targetFile, encoding: .utf8),
            "term_b\n"
        )
    }

    func testAssistantPanelStartsCodexNativeAgentSessionInDedicatedWorkspace() {
        let launcher = RecordingLocalAgentProcessLauncher()
        let panel = makeAssistantPanel(
            localAgentToolResolver: StaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"]),
            localAgentProcessLauncherFactory: { launcher }
        )

        panel.loadView()

        XCTAssertEqual(panel.surfaceModeTitlesForTesting, ["排查助手", "本地 Agent"])
        XCTAssertEqual(panel.activeSurfaceModeTitleForTesting, "排查助手")
        XCTAssertEqual(
            panel.localAgentToolTitlesForTesting,
            [
                "Codex",
                "Claude（未检测到）",
                "OpenCode（未检测到）",
                "MiMo Code（未检测到）",
                "ZCode（未检测到）",
                "Qwen Code（未检测到）"
            ]
        )
        XCTAssertTrue(panel.localAgentWorkspaceHiddenForTesting)
        XCTAssertFalse(panel.assistantTranscriptHiddenForTesting)
        XCTAssertFalse(panel.composerHiddenForTesting)
        XCTAssertTrue(panel.localAgentTerminalHostHiddenForTesting)
        XCTAssertFalse(panel.transcriptContentOrderForTesting.contains("localAgent"))

        panel.startLocalAgentForTesting(.codex)

        XCTAssertEqual(panel.activeSurfaceModeTitleForTesting, "本地 Agent")
        XCTAssertFalse(panel.localAgentWorkspaceHiddenForTesting)
        XCTAssertTrue(panel.assistantTranscriptHiddenForTesting)
        XCTAssertTrue(panel.composerHiddenForTesting)
        XCTAssertFalse(panel.localAgentTerminalHostHiddenForTesting)
        XCTAssertEqual(launcher.startedExecutable, "/tools/codex")
        XCTAssertEqual(launcher.startedCurrentDirectory, LocalAgentBridgeToolInstaller.defaultWorkspaceDirectory())
        XCTAssertEqual(launcher.startedEnvironmentDictionary["STACIO_REMOTE_CURRENT_DIRECTORY"], "/srv/app")
        XCTAssertTrue(panel.localAgentStatusTextForTesting.contains("Codex 原生会话已启动"))
    }

    func testSurfaceModeSegmentsFillFirstVisibleLayoutAfterPanelStartsAtZeroWidth() {
        let panel = makeAssistantPanel()

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 360, height: 720)
        panel.view.needsLayout = true
        panel.view.layoutSubtreeIfNeeded()

        let controlWidth = panel.surfaceModeControlWidthForTesting
        let segmentWidths = panel.surfaceModeSegmentWidthsForTesting
        XCTAssertGreaterThan(controlWidth, 0)
        XCTAssertEqual(segmentWidths.count, 2)
        XCTAssertEqual(segmentWidths.reduce(0, +), controlWidth, accuracy: 1)
        XCTAssertEqual(segmentWidths[0], segmentWidths[1], accuracy: 1)
        XCTAssertTrue(segmentWidths.allSatisfy { $0 > 0 })
    }

    func testLocalAgentSelectorUsesPopupAndMarksMissingTools() throws {
        let panel = makeAssistantPanel(
            localAgentToolResolver: StaticLocalAgentToolResolver(paths: [
                .codex: "/tools/codex",
                .mimoCode: "/tools/mimo"
            ])
        )

        panel.loadView()

        let popup = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.localAgent.selector") as? NSPopUpButton
        )
        XCTAssertEqual(
            popup.itemArray.map(\.title),
            [
                "Codex",
                "Claude（未检测到）",
                "OpenCode（未检测到）",
                "MiMo Code",
                "ZCode（未检测到）",
                "Qwen Code（未检测到）"
            ]
        )
        XCTAssertEqual(popup.itemArray.map(\.isEnabled), [true, false, false, true, false, false])
    }

    func testLocalAgentModeHidesAssistantComposerHistoryAndCommandCards() {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            AgentTaskSessionRecord(
                id: "task-recent",
                requestId: "req-recent",
                actorKind: "builtInAI",
                actorName: "Stacio AI",
                targetRuntimeId: "term_1",
                targetTitle: "dev@example.com",
                state: "awaitingUser",
                userPrompt: "看一下 docker",
                assistantMessage: "建议检查 compose。",
                createdAt: "2026-06-06T00:00:00Z",
                updatedAt: "2026-06-06T00:01:00Z",
                proposals: [
                    AgentTaskProposalRecord(
                        id: "proposal-recent",
                        command: "docker compose version",
                        explanation: "检查 compose",
                        risk: "readOnly",
                        state: "proposed",
                        sortOrder: 0,
                        createdAt: "2026-06-06T00:00:00Z",
                        updatedAt: "2026-06-06T00:01:00Z"
                    )
                ]
            )
        ]
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: .init(
                    message: "建议检查版本。",
                    proposedCommand: "docker compose version"
                )
            ),
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskLister: taskStore,
            localAgentToolResolver: StaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"])
        )

        panel.loadView()
        panel.setQuestionForTesting("看一下 docker")
        panel.performAskForTesting()

        XCTAssertFalse(panel.taskHistoryHiddenForTesting)
        XCTAssertTrue(waitUntil { panel.commandCardsHiddenForTesting == false })
        XCTAssertFalse(panel.commandCardsHiddenForTesting)

        panel.switchSurfaceModeForTesting("本地 Agent")

        XCTAssertTrue(panel.assistantTranscriptHiddenForTesting)
        XCTAssertTrue(panel.composerHiddenForTesting)
        XCTAssertTrue(panel.commandCardsHiddenForTesting)
        XCTAssertFalse(panel.localAgentWorkspaceHiddenForTesting)
    }

    func testAssistantPanelKeepsNativeAgentSessionAliveWhenSwitchingTools() {
        let codexLauncher = RecordingLocalAgentProcessLauncher()
        let claudeLauncher = RecordingLocalAgentProcessLauncher()
        var launchers: [RecordingLocalAgentProcessLauncher] = [codexLauncher, claudeLauncher]
        let panel = makeAssistantPanel(
            localAgentToolResolver: StaticLocalAgentToolResolver(paths: [
                .codex: "/tools/codex",
                .claude: "/tools/claude"
            ]),
            localAgentProcessLauncherFactory: {
                launchers.removeFirst()
            }
        )

        panel.loadView()
        panel.startLocalAgentForTesting(.codex)
        panel.startLocalAgentForTesting(.claude)
        panel.startLocalAgentForTesting(.codex)

        XCTAssertEqual(codexLauncher.startCount, 1)
        XCTAssertEqual(claudeLauncher.startCount, 1)
        XCTAssertEqual(codexLauncher.startedExecutable, "/tools/codex")
        XCTAssertEqual(claudeLauncher.startedExecutable, "/tools/claude")
        XCTAssertTrue(panel.localAgentStatusTextForTesting.contains("Codex 原生会话已启动"))
    }

    func testOpenAICompatibleProviderRequiresSettingsKeyBeforeNetworkRequest() throws {
        let transport = RecordingAIAssistantHTTPTransport(responseBody: "{}")
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { nil },
            transport: transport
        )

        XCTAssertThrowsError(
            try provider.respond(
                to: AIAssistantRequest(
                    question: "帮我看一下",
                    context: AITerminalContext(
                        runtimeID: "term_ssh",
                        title: "root@centos7",
                        currentDirectory: nil,
                        recentTranscript: ""
                    )
                )
            )
        ) { error in
            XCTAssertTrue(RuntimeDiagnosticFormatter.userMessage(for: error).contains("API Key"))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testOpenAICompatibleProviderAllowsLocalEndpointWithoutAPIKey() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "本地模型可用。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "http://localhost:11434/v1")),
            model: "local-model",
            apiKeyProvider: { nil },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "本地模型可用。")
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatibleProviderAddsConfiguredUserAgentHeader() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "带请求标识。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            maxRetryCount: 0,
            userAgent: "  Stacio-QA/1.0  ",
            requestTimeoutSeconds: 12
        )

        _ = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "User-Agent"), "Stacio-QA/1.0")
        XCTAssertEqual(transport.requests.first?.timeoutInterval, 12)
    }

    func testOpenAICompatibleProviderStripsControlCharactersFromUserAgentHeader() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "Header 已清理。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            maxRetryCount: 0,
            userAgent: "Stacio\tQA\u{0000}/1.0\r\nInjected: evil\u{001B}",
            requestTimeoutSeconds: 12
        )

        _ = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "User-Agent"),
            "Stacio QA /1.0 Injected: evil"
        )
    }

    func testOpenAICompatibleProviderStripsControlCharactersFromModelInRequestBody() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "模型名已清理。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops\tmodel\u{0000}\r\ninjected\u{001B}",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            maxRetryCount: 0
        )

        _ = try provider.respond(to: makeAIRequest())

        let body = try XCTUnwrap(transport.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "ops model injected")
    }

    func testOpenAICompatibleProviderIncludesReasoningEffortWhenConfigured() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "推理参数已发送。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            reasoningEffort: .high
        )

        _ = try provider.respond(to: makeAIRequest())

        let body = String(data: try XCTUnwrap(transport.requests.first?.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""reasoning_effort":"high""#))
    }

    func testOpenAICompatibleProviderSendsImageAttachmentsAsChatContentParts() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "已看到图片。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        _ = try provider.respond(
            to: AIAssistantRequest(
                question: "看一下截图",
                context: makeAIRequest().context,
                attachments: [
                    AIAssistantAttachment(
                        filename: "screen.png",
                        mimeType: "image/png",
                        byteCount: 3,
                        base64Data: "YWJj"
                    )
                ]
            )
        )

        let body = String(data: try XCTUnwrap(transport.requests.first?.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""type":"image_url""#))
        XCTAssertTrue(body.contains(#""url":"data:image\/png;base64,YWJj""#))
        XCTAssertTrue(body.contains("screen.png"))
    }

    func testOpenAICompatibleProviderSendsImageAttachmentsAsResponsesInputParts() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/responses": (200, #"{"output_text":"{\"message\":\"已看到图片。\",\"commands\":[]}"}"#)
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            compatibilityProtocol: .responses
        )

        _ = try provider.respond(
            to: AIAssistantRequest(
                question: "看一下截图",
                context: makeAIRequest().context,
                attachments: [
                    AIAssistantAttachment(
                        filename: "screen.png",
                        mimeType: "image/png",
                        byteCount: 3,
                        base64Data: "YWJj"
                    )
                ]
            )
        )

        let body = String(data: try XCTUnwrap(transport.requests.first?.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""type":"input_image""#))
        XCTAssertTrue(body.contains(#""url":"data:image\/png;base64,YWJj""#))
        XCTAssertTrue(body.contains("screen.png"))
    }

    func testOpenAICompatibleProviderRetriesTransientServerErrorOnSameEndpoint() throws {
        let transport = SequencedAIAssistantHTTPTransport(responses: [
            (500, #"{"error":{"message":"temporary upstream failure"}}"#),
            (200, chatCompletionBody(message: "重试成功。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            maxRetryCount: 1,
            userAgent: "Stacio"
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "重试成功。")
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, [
            "/v1/chat/completions",
            "/v1/chat/completions"
        ])
    }

    func testOpenAICompatibleProviderDoesNotRetryAuthenticationFailure() throws {
        let transport = SequencedAIAssistantHTTPTransport(responses: [
            (401, #"{"error":{"message":"Invalid API key"}}"#),
            (200, chatCompletionBody(message: "不应请求到这里。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            maxRetryCount: 2,
            userAgent: "Stacio"
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertTrue(RuntimeDiagnosticFormatter.userMessage(for: error).contains("API Key"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testOpenAICompatibleModelCatalogFetchesModelsEndpoint() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/models": (
                200,
                """
                {
                  "data": [
                    {"id": "gpt-4.1-mini"},
                    {"id": "qwen2.5-coder"},
                    {"id": "gpt-4.1-mini"}
                  ]
                }
                """
            )
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(
            for: makePanelCatalogProvider(
                baseURL: "https://api.example.com/v1",
                requestTimeoutSeconds: 10
            ),
            apiKey: "sk-test-secret"
        )

        XCTAssertEqual(models, ["gpt-4.1-mini", "qwen2.5-coder"])
        XCTAssertEqual(transport.requests.map { $0.url?.path }, ["/v1/models"])
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-secret")
    }

    func testOpenAICompatibleModelCatalogStripsControlCharactersFromModelIDs() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/models": (
                200,
                """
                {
                  "data": [
                    {"id": "ops\\tmodel\\u0000\\r\\nalpha\\u001B"},
                    {"id": "ops model alpha"},
                    {"id": "\\u0000\\u001B"}
                  ]
                }
                """
            )
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(
            for: makePanelCatalogProvider(baseURL: "https://api.example.com/v1"),
            apiKey: "sk-test-secret"
        )

        XCTAssertEqual(models, ["ops model alpha"])
    }

    func testOpenAICompatibleModelCatalogAllowsLocalEndpointWithoutAPIKey() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/models": (200, #"{"data":[{"id":"local-model"}]}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(
            for: makePanelCatalogProvider(baseURL: "http://localhost:11434/v1"),
            apiKey: nil
        )

        XCTAssertEqual(models, ["local-model"])
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testOpenAICompatibleModelCatalogRetriesTransientServerErrorOnSameEndpoint() throws {
        let transport = SequencedAIAssistantHTTPTransport(responses: [
            (500, #"{"error":{"message":"temporary model catalog failure"}}"#),
            (200, #"{"data":[{"id":"ops-model"}]}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        let models = try catalog.listModels(
            for: makePanelCatalogProvider(
                baseURL: "https://api.example.com/v1",
                maxRetryCount: 1
            ),
            apiKey: "sk-test-secret"
        )

        XCTAssertEqual(models, ["ops-model"])
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, [
            "/v1/models",
            "/v1/models"
        ])
    }

    func testOpenAICompatibleModelCatalogDoesNotRetryAuthenticationFailure() throws {
        let transport = SequencedAIAssistantHTTPTransport(responses: [
            (401, #"{"error":{"message":"Invalid API key"}}"#),
            (200, #"{"data":[{"id":"should-not-load"}]}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        XCTAssertThrowsError(
            try catalog.listModels(
                for: makePanelCatalogProvider(
                    baseURL: "https://api.example.com/v1",
                    maxRetryCount: 2
                ),
                apiKey: "sk-test-secret"
            )
        ) { error in
            XCTAssertTrue(RuntimeDiagnosticFormatter.userMessage(for: error).contains("API Key"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testOpenAICompatibleModelCatalogReportsSanitizedTopLevelDetailErrorBody() throws {
        let transport = SequencedAIAssistantHTTPTransport(responses: [
            (500, #"{"detail":"model registry unavailable token=registry-secret"}"#)
        ])
        let catalog = OpenAICompatibleAIModelCatalog(transport: transport)

        XCTAssertThrowsError(
            try catalog.listModels(
                for: makePanelCatalogProvider(
                    baseURL: "https://api.example.com/v1",
                    maxRetryCount: 0
                ),
                apiKey: "sk-test-secret"
            )
        ) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("HTTP 500"))
            XCTAssertTrue(message.contains("model registry unavailable"))
            XCTAssertFalse(message.contains("registry-secret"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testOpenAICompatibleProviderReportsNonJSONResponseWithoutRawDecoderError() throws {
        let transport = RecordingAIAssistantHTTPTransport(responseBody: "<html>login</html>")
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(
            try provider.respond(
                to: AIAssistantRequest(
                    question: "帮我看一下",
                    context: AITerminalContext(
                        runtimeID: "term_ssh",
                        title: "root@centos7",
                        currentDirectory: "/root",
                        recentTranscript: ""
                    )
                )
            )
        ) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("不是 JSON"))
            XCTAssertFalse(message.contains("DecodingError"))
            XCTAssertFalse(message.contains("Unexpected character"))
            XCTAssertFalse(message.contains("已隐藏路径"))
        }
    }

    func testOpenAICompatibleProviderReportsMalformedAssistantPayloadWithoutRawContent() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                200,
                chatCompletionBody(rawContent: #"{"message":"缺少结尾""#)
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("格式异常"))
            XCTAssertTrue(message.contains("重试"))
            XCTAssertFalse(message.contains("缺少结尾"))
        }
    }

    func testOpenAICompatibleProviderReportsReadableOpenAIErrorBody() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                400,
                """
                {
                  "error": {
                    "message": "The model `bad-model` does not exist or you do not have access to it.",
                    "type": "invalid_request_error",
                    "code": "model_not_found"
                  }
                }
                """
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "bad-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("模型"))
            XCTAssertTrue(message.contains("bad-model"))
            XCTAssertTrue(message.contains("HTTP 400"))
            XCTAssertFalse(message.contains("DecodingError"))
        }
    }

    func testOpenAICompatibleProviderReportsSanitizedTopLevelDetailErrorBody() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                400,
                #"{"detail":"context length exceeded api_key=leaked-secret"}"#
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("HTTP 400"))
            XCTAssertTrue(message.contains("context length exceeded"))
            XCTAssertFalse(message.contains("leaked-secret"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
    }

    func testOpenAICompatibleProviderReportsSanitizedDetailArrayErrorBody() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                422,
                """
                {
                  "detail": [
                    {"loc":["body","model"],"msg":"model field required token=validation-secret","type":"value_error.missing"},
                    {"loc":["body","temperature"],"msg":"temperature must be between 0 and 2"}
                  ]
                }
                """
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("HTTP 422"))
            XCTAssertTrue(message.contains("model field required"))
            XCTAssertTrue(message.contains("temperature must be between 0 and 2"))
            XCTAssertFalse(message.contains("validation-secret"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
    }

    func testOpenAICompatibleProviderRedactsAPIKeyFromErrorBody() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                401,
                #"{"error":{"message":"Invalid API key sk-test-secret for this project"}}"#
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("API Key"))
            XCTAssertTrue(message.contains("HTTP 401"))
            XCTAssertFalse(message.contains("sk-test-secret"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
    }

    func testOpenAICompatibleProviderRedactsBearerAndKeyValueSecretsFromErrorBody() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                401,
                #"{"error":{"message":"Authorization: Bearer sk-test-secret api_key=plain-secret token=tok-secret password: pass-secret"}}"#
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("HTTP 401"))
            XCTAssertFalse(message.contains("sk-test-secret"))
            XCTAssertFalse(message.contains("plain-secret"))
            XCTAssertFalse(message.contains("tok-secret"))
            XCTAssertFalse(message.contains("pass-secret"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
    }

    func testOpenAICompatibleProviderRedactsSpacedAPIKeySecretsFromErrorBody() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                401,
                #"{"error":{"message":"upstream rejected API key ghp_live123456789 for this project"}}"#
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            guard case AIAssistantProviderError.apiError(_, let providerMessage) = error else {
                return XCTFail("expected API error")
            }
            XCTAssertFalse(providerMessage.contains("ghp_live123456789"))
            XCTAssertTrue(providerMessage.contains("API key [已隐藏凭据]"))

            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertTrue(message.contains("HTTP 401"))
            XCTAssertFalse(message.contains("ghp_live123456789"))
            XCTAssertTrue(message.contains("API key [已隐藏凭据]"))
        }
    }

    func testOpenAICompatibleProviderRedactsExactOpaqueAPIKeyEchoedByUpstream() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                401,
                #"{"error":{"message":"upstream rejected opaqueABC123XYZ value"}}"#
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "opaqueABC123XYZ" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            let message = RuntimeDiagnosticFormatter.userMessage(for: error)
            XCTAssertFalse(message.contains("opaqueABC123XYZ"))
            XCTAssertTrue(message.contains("已隐藏"))
        }
    }

    func testOpenAICompatibleProviderRejectsPublicHTTPBaseURLWhenAPIKeyWouldBeSent() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "不应发出请求。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "http://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL)
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testOpenAICompatibleProviderRejectsPrivateHTTPBaseURLWithAPIKey() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "不应发出请求。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "http://192.168.1.10:11434/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .insecureBaseURL)
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testOpenAICompatibleProviderFallsBackFromNonJSONRootEndpointToV1ChatCompletions() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/chat/completions": (200, "<html>login</html>"),
            "/v1/chat/completions": (200, chatCompletionBody(message: "已连接兼容接口。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "已连接兼容接口。")
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, [
            "/chat/completions",
            "/v1/chat/completions"
        ])
    }

    func testOpenAICompatibleProviderPreservesProxyPrefixWhenTryingV1Fallback() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/api/openai/chat/completions": (404, "{\"error\":\"not found\"}"),
            "/api/openai/v1/chat/completions": (200, chatCompletionBody(message: "代理前缀可用。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://proxy.example.com/api/openai")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "代理前缀可用。")
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, [
            "/api/openai/chat/completions",
            "/api/openai/v1/chat/completions"
        ])
    }

    func testOpenAICompatibleProviderUsesExactChatCompletionsEndpointWithoutAddingPath() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "完整地址可用。"))
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1/chat/completions")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "完整地址可用。")
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/v1/chat/completions"])
    }

    func testOpenAICompatibleProviderParsesContentPartsResponse() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                200,
                """
                {
                  "choices": [
                    {
                      "message": {
                        "content": [
                          {"type":"text","text":"{\\"message\\":\\"兼容 content parts。\\",\\"commands\\":[{\\"command\\":\\"uname -a\\",\\"explanation\\":\\"查看内核版本\\"}]}"}
                        ]
                      }
                    }
                  ]
                }
                """
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "兼容 content parts。")
        XCTAssertEqual(response.commandProposals.map(\.command), ["uname -a"])
    }

    func testOpenAICompatibleProviderParsesMessageOnlyJSONPayload() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                200,
                chatCompletionBody(rawContent: #"{"message":"当前没有需要执行的命令。"}"#)
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "当前没有需要执行的命令。")
        XCTAssertTrue(response.commandProposals.isEmpty)
    }

    func testOpenAICompatibleProviderParsesSingleCommandJSONPayload() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (
                200,
                chatCompletionBody(rawContent: #"{"message":"建议看负载。","command":"uptime","explanation":"查看系统负载"}"#)
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "建议看负载。")
        XCTAssertEqual(response.commandProposals.map(\.command), ["uptime"])
        XCTAssertEqual(response.commandProposals.map(\.explanation), ["查看系统负载"])
    }

    func testAIProviderFactoryAcceptsBaseURLWithoutScheme() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "自动补全协议。"))
        ])
        let provider = makeFactoryProvider(
            baseURL: "api.example.com/v1",
            apiKey: "sk-factory-secret",
            maxRetryCount: 0,
            requestTimeoutSeconds: 18,
            userAgent: "Stacio-Factory/1.0",
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "自动补全协议。")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "User-Agent"), "Stacio-Factory/1.0")
        XCTAssertEqual(transport.requests.first?.timeoutInterval, 18)
    }

    func testAIProviderFactoryRejectsBaseURLWithInvalidExplicitPort() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "不应发出请求。"))
        ])
        let provider = makeFactoryProvider(
            baseURL: "https://api.example.com:99999/v1",
            apiKey: "sk-factory-secret",
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .invalidBaseURL)
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testAIProviderFactoryRejectsCredentialedBaseURLBeforeNetworkRequest() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "不应发出请求。"))
        ])
        let provider = makeFactoryProvider(
            baseURL: "https://api-token@api.example.com/v1",
            apiKey: "sk-factory-secret",
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .invalidBaseURL)
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testAIProviderFactoryRejectsBaseURLWithWhitespaceInsideValue() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v%201/chat/completions": (200, chatCompletionBody(message: "不应发出请求。"))
        ])
        let provider = makeFactoryProvider(
            baseURL: "https://api.example.com/v 1",
            apiKey: "sk-factory-secret",
            transport: transport
        )

        XCTAssertThrowsError(try provider.respond(to: makeAIRequest())) { error in
            XCTAssertEqual(error as? AIAssistantProviderError, .invalidBaseURL)
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testAIProviderFactoryDefaultsPrivateBaseURLWithoutSchemeToHTTPS() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "私网 HTTPS 模型服务可用。"))
        ])
        let provider = makeFactoryProvider(
            baseURL: "192.168.1.10:11434/v1",
            apiKey: "sk-private-secret",
            maxRetryCount: 0,
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "私网 HTTPS 模型服务可用。")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://192.168.1.10:11434/v1/chat/completions")
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-private-secret")
    }

    func testAIProviderFactoryDefaultsPrivateIPv6BaseURLWithoutSchemeToHTTPS() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "私网 IPv6 HTTPS 模型服务可用。"))
        ])
        let provider = makeFactoryProvider(
            baseURL: "[fd00::10]:11434/v1",
            apiKey: "sk-private-ipv6-secret",
            maxRetryCount: 0,
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "私网 IPv6 HTTPS 模型服务可用。")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "https://[fd00::10]:11434/v1/chat/completions")
        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-private-ipv6-secret"
        )
    }

    func testAIProviderFactoryDefaultsLocalhostBaseURLWithoutSchemeToHTTP() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/chat/completions": (200, chatCompletionBody(message: "本机模型服务可用。"))
        ])
        let provider = makeFactoryProvider(
            baseURL: "localhost:11434/v1",
            apiKey: nil,
            maxRetryCount: 0,
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "本机模型服务可用。")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(transport.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAIProviderFactoryUsesResponsesCompatibilityProtocol() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/responses": (
                200,
                """
                {
                  "output": [
                    {
                      "content": [
                        {
                          "type": "output_text",
                          "text": "{\\"message\\":\\"建议查看系统负载。\\",\\"commands\\":[{\\"command\\":\\"uptime\\",\\"explanation\\":\\"查看负载\\"}]}"
                        }
                      ]
                    }
                  ]
                }
                """
            )
        ])
        let provider = makeFactoryProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-factory-secret",
            maxRetryCount: 0,
            compatibilityProtocol: .responses,
            transport: transport
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "建议查看系统负载。")
        XCTAssertEqual(response.commandProposals.map(\.command), ["uptime"])
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/v1/responses"])
        let body = String(data: try XCTUnwrap(transport.requests.first?.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(#""instructions":"#))
        XCTAssertTrue(body.contains(#""input":"#))
        XCTAssertFalse(body.contains(#""messages":"#))
        XCTAssertTrue(body.contains(#""reasoning":{"effort":"medium"}"#))
    }

    func testOpenAICompatibleProviderParsesResponsesOutputTextField() throws {
        let transport = RoutingAIAssistantHTTPTransport(routes: [
            "/v1/responses": (
                200,
                #"{"output_text":"{\"message\":\"响应文本可用。\",\"commands\":[]}"}"#
            )
        ])
        let provider = OpenAICompatibleAIAssistantProvider(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com/v1")),
            model: "ops-model",
            apiKeyProvider: { "sk-test-secret" },
            transport: transport,
            compatibilityProtocol: .responses
        )

        let response = try provider.respond(to: makeAIRequest())

        XCTAssertEqual(response.message, "响应文本可用。")
        XCTAssertEqual(response.commandProposals, [])
        XCTAssertEqual(transport.requests.compactMap { $0.url?.path }, ["/v1/responses"])
    }

    func testAIProviderFactoryUsesOpenAICompatibleSettingsAndKeychainAPIKey() throws {
        let provider = makeFactoryProvider(
            baseURL: "https://api.example.com/v1",
            apiKey: "sk-factory-secret",
            transport: RecordingAIAssistantHTTPTransport(responseBody: "{}")
        )

        XCTAssertTrue(provider is OpenAICompatibleAIAssistantProvider)
    }

    func testAIProviderFactoryTreatsNamedVendorsAsOpenAICompatibleProviders() throws {
        let provider = makeFactoryProvider(
            profile: .deepSeek,
            baseURL: "https://api.deepseek.com/v1",
            modelID: "deepseek-chat",
            apiKey: "sk-deepseek-secret",
            transport: RecordingAIAssistantHTTPTransport(responseBody: "{}")
        )

        XCTAssertTrue(provider is OpenAICompatibleAIAssistantProvider)
    }

    func testAssistantResponseBuildsStructuredProposalFromLegacyCommand() throws {
        let response = AIAssistantResponse(message: "查看磁盘", proposedCommand: "df -h")

        XCTAssertEqual(response.proposedCommand, "df -h")
        XCTAssertEqual(response.commandProposals.count, 1)
        XCTAssertEqual(response.commandProposals[0].command, "df -h")
        XCTAssertEqual(response.commandProposals[0].risk, .readOnly)
        XCTAssertEqual(response.commandProposals[0].state, .proposed)
    }

    func testAssistantResponseKeepsExplicitCommandProposals() throws {
        let proposal = AgentCommandProposal(
            id: "proposal-1",
            command: "rm -rf /tmp/build",
            explanation: "删除临时构建目录",
            risk: .destructive,
            state: .proposed
        )
        let response = AIAssistantResponse(message: "谨慎执行", commandProposals: [proposal])

        XCTAssertEqual(response.proposedCommand, "rm -rf /tmp/build")
        XCTAssertEqual(response.commandProposals, [proposal])
    }

    func testRuleBasedAssistantReturnsStructuredMultiStepDiagnosticsForDiskAndContainers() throws {
        let provider = RuleBasedAIAssistantProvider()

        let response = try provider.respond(
            to: AIAssistantRequest(
                question: "磁盘快满了，顺便看看 docker 占用",
                context: AITerminalContext(
                    runtimeID: "term_1",
                    title: "prod@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            )
        )

        XCTAssertTrue(response.message.contains("分步"))
        XCTAssertEqual(response.commandProposals.map(\.command), [
            "df -h",
            "du -sh ./* 2>/dev/null | sort -h | tail -20",
            "docker system df"
        ])
        XCTAssertTrue(response.commandProposals.allSatisfy { $0.risk == .readOnly })
        XCTAssertTrue(response.commandProposals.allSatisfy { $0.explanation.isEmpty == false })
    }

    func testRuleBasedAssistantReturnsStructuredLoadDiagnosticsForChineseLoadQuestion() throws {
        let provider = RuleBasedAIAssistantProvider()

        let response = try provider.respond(
            to: AIAssistantRequest(
                question: "系统负载很高，CPU 也高，帮我看一下",
                context: AITerminalContext(
                    runtimeID: "term_1",
                    title: "prod@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            )
        )

        XCTAssertTrue(response.message.contains("分步"))
        XCTAssertEqual(response.commandProposals.map(\.command), [
            "uptime",
            "ps aux --sort=-%cpu | head -10",
            "free -h"
        ])
        XCTAssertTrue(response.commandProposals.allSatisfy { $0.risk == .readOnly })
        XCTAssertTrue(response.commandProposals.allSatisfy { $0.explanation.isEmpty == false })
    }

    func testRuleBasedAssistantReturnsContainerDiagnosticsForDockerQuestion() throws {
        let provider = RuleBasedAIAssistantProvider()

        let response = try provider.respond(
            to: AIAssistantRequest(
                question: "帮我看看 docker 容器状态",
                context: AITerminalContext(
                    runtimeID: "term_1",
                    title: "prod@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            )
        )

        XCTAssertTrue(response.message.contains("分步"))
        XCTAssertEqual(response.commandProposals.map(\.command), [
            "docker ps",
            "docker system df",
            "docker images | head -20"
        ])
        XCTAssertTrue(response.commandProposals.allSatisfy { $0.risk == .readOnly })
        XCTAssertTrue(response.commandProposals.allSatisfy { $0.explanation.isEmpty == false })
    }

    func testRuleBasedAssistantRendersMultiStepDiagnosticCommandCards() throws {
        let panel = makeAssistantPanel(
            provider: RuleBasedAIAssistantProvider(),
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 300, height: 520)
        panel.setQuestionForTesting("磁盘快满了，顺便看看 docker 占用")
        panel.performAskForTesting()
        panel.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 3 })
        XCTAssertTrue(panel.assistantTranscriptTextForTesting.contains("分步"))
        XCTAssertTrue(panel.commandCardTextForTesting(at: 0).contains("df -h"))
        XCTAssertTrue(panel.commandCardTextForTesting(at: 1).contains("du -sh ./* 2>/dev/null | sort -h | tail -20"))
        XCTAssertTrue(panel.commandCardTextForTesting(at: 2).contains("docker system df"))
        XCTAssertLessThanOrEqual(panel.commandCardsStackFrameForTesting.width, panel.view.bounds.width)
    }

    func testAssistantSkipCommandCardRecordsSpecificSkippedCommandInTranscript() throws {
        let panel = makeAssistantPanel(
            provider: RuleBasedAIAssistantProvider(),
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("磁盘快满了，顺便看看 docker 占用")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 3 })

        panel.skipCommandCardForTesting(at: 1)

        XCTAssertTrue(panel.commandCardTextForTesting(at: 1).contains("已跳过"))
        XCTAssertTrue(panel.statusTextForTesting.contains("du -sh ./* 2>/dev/null | sort -h | tail -20"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("已跳过命令：du -sh ./* 2>/dev/null | sort -h | tail -20"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("风险：只读"))
    }

    func testAssistantPanelRestoresConversationHistoryForCurrentRuntime() throws {
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "旧问题：看磁盘"),
            makeHistoryRecord(runtimeID: "term_1", role: .step, content: "思考：建议先执行 df -h"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ df -h\nFilesystem 42%",
                requestID: "agent-step-history-1"
            ),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "旧结论：磁盘占用正常"),
            makeHistoryRecord(runtimeID: "term_other", role: .assistant, content: "其他会话回复")
        ]
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            conversationHistoryStore: historyStore
        )

        panel.loadView()

        XCTAssertTrue(panel.transcriptTextForTesting.contains("旧问题：看磁盘"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("旧结论：磁盘占用正常"))
        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("Filesystem 42%"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("Filesystem 42%"))
        XCTAssertEqual(panel.collapsedProcessEntryCountForTesting, 2)
        XCTAssertEqual(panel.processGroupCountForTesting, 1)
        XCTAssertTrue(panel.processGroupSummaryTextsForTesting.first?.hasPrefix("已处理 ") == true)
        panel.expandAllProcessEntriesForTesting()
        XCTAssertTrue(panel.transcriptTextForTesting.contains("思考：建议先执行 df -h"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("Filesystem 42%"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("其他会话回复"))
        XCTAssertTrue(historyStore.listedRuntimeIDs.contains("term_1"))
    }

    func testAssistantPanelFoldsLegacyPreliminaryAssistantReplyIntoProcessHistory() throws {
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "查看 CPU"),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "我先读取 CPU 状态。"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ top -l 1\nCPU idle 98%",
                requestID: "agent-step-legacy-1"
            ),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "CPU 当前负载很低，运行正常。")
        ]
        let panel = makeAssistantPanel(conversationHistoryStore: historyStore)

        panel.loadView()

        XCTAssertEqual(panel.assistantConclusionTextsForTesting, ["CPU 当前负载很低，运行正常。"])
        XCTAssertEqual(panel.processGroupCountForTesting, 1)
        XCTAssertGreaterThan(panel.collapsedThinkingEntryCountForTesting, 0)
        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("我先读取 CPU 状态。"))
    }

    func testAssistantHistoryOmitsTrailingTerminalTraceWithoutAssistantConclusion() throws {
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "删除测试文件"),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "已删除 /root/test.txt 文件。"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · 雨云\n$ free -h\nexternal local Agent output"
            )
        ]
        let panel = makeAssistantPanel(conversationHistoryStore: historyStore)

        panel.loadView()

        XCTAssertTrue(panel.assistantTranscriptTextForTesting.contains("已删除 /root/test.txt 文件。"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("free -h"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("external local Agent output"))
        XCTAssertEqual(panel.processGroupCountForTesting, 0)
    }

    func testAssistantHistoryOmitsExternalCLIProcessBeforeAssistantConclusion() throws {
        let externalRequestID = "7C0E8D7B-9270-4728-87B0-5C3E41E74954"
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "查看内存"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ free -h\nexternal local Agent output",
                requestID: externalRequestID
            ),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "内存状态正常。")
        ]
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-external-history",
                requestID: externalRequestID,
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "free -h",
                actorKind: AgentActorKind.externalCLI.rawValue,
                actorName: "codex"
            )
        ]
        let panel = makeAssistantPanel(
            taskLister: taskStore,
            conversationHistoryStore: historyStore
        )

        panel.loadView()

        XCTAssertTrue(panel.assistantTranscriptTextForTesting.contains("内存状态正常。"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("free -h"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("external local Agent output"))
        XCTAssertEqual(panel.processGroupCountForTesting, 0)
    }

    func testAssistantHistoryOmitsTerminalWithoutRequestIDButKeepsBuiltInPlanAndStep() throws {
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "查看负载"),
            makeHistoryRecord(runtimeID: "term_1", role: .plan, content: "计划：先查看系统负载"),
            makeHistoryRecord(runtimeID: "term_1", role: .step, content: "正在分析终端状态"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ uptime\nexternal terminal history"
            ),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "系统负载正常。")
        ]
        let panel = makeAssistantPanel(conversationHistoryStore: historyStore)

        panel.loadView()

        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("计划：先查看系统负载"))
        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("正在分析终端状态"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("external terminal history"))
        XCTAssertEqual(panel.collapsedProcessEntryCountForTesting, 2)
        XCTAssertEqual(panel.processGroupCountForTesting, 1)
    }

    func testAssistantHistoryScopesRequestOwnershipToRuntime() throws {
        let sharedRequestID = "6F6CF0E6-A0D0-4D5A-93A2-F59813115C75"
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "查看内存"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ free -h\nexternal current-runtime output",
                requestID: sharedRequestID
            ),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "内存状态正常。")
        ]
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-built-in-other-runtime",
                requestID: sharedRequestID,
                runtimeID: "term_other",
                title: "other@example.com",
                command: "free -h"
            ),
            makeAgentTaskSessionRecord(
                id: "task-external-current-runtime",
                requestID: sharedRequestID,
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "free -h",
                actorKind: AgentActorKind.externalCLI.rawValue,
                actorName: "codex"
            )
        ]
        let panel = makeAssistantPanel(
            taskLister: taskStore,
            conversationHistoryStore: historyStore
        )

        panel.loadView()

        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("external current-runtime output"))
        XCTAssertEqual(panel.assistantConclusionTextsForTesting, ["内存状态正常。"])
        XCTAssertEqual(panel.processGroupCountForTesting, 0)
    }

    func testAssistantHistoryDoesNotTrustAgentStepPrefixOwnedOnlyByOtherRuntimes() throws {
        let sharedRequestID = "agent-step-shared-runtime-1"
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "查看进程"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ ps aux\ncross-runtime agent output",
                requestID: sharedRequestID
            ),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "进程状态正常。")
        ]
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-built-in-other-runtime-agent-step",
                requestID: sharedRequestID,
                runtimeID: "term_other_built_in",
                title: "built-in@example.com",
                command: "ps aux"
            ),
            makeAgentTaskSessionRecord(
                id: "task-external-other-runtime-agent-step",
                requestID: sharedRequestID,
                runtimeID: "term_other_external",
                title: "external@example.com",
                command: "ps aux",
                actorKind: AgentActorKind.externalCLI.rawValue,
                actorName: "codex"
            )
        ]
        let panel = makeAssistantPanel(
            taskLister: taskStore,
            conversationHistoryStore: historyStore
        )

        panel.loadView()

        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("cross-runtime agent output"))
        XCTAssertEqual(panel.assistantConclusionTextsForTesting, ["进程状态正常。"])
        XCTAssertEqual(panel.processGroupCountForTesting, 0)
    }

    func testAssistantHistoryTreatsMixedActorsForSameRuntimeRequestAsAmbiguous() throws {
        let requestID = "E5FBC182-7B61-4FD5-B4A6-93F46F747C3D"
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "查看磁盘"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ df -h\nambiguous actor output",
                requestID: requestID
            ),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "磁盘状态正常。")
        ]
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-built-in-ambiguous",
                requestID: requestID,
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "df -h"
            ),
            makeAgentTaskSessionRecord(
                id: "task-external-ambiguous",
                requestID: requestID,
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "df -h",
                actorKind: AgentActorKind.externalCLI.rawValue,
                actorName: "codex"
            )
        ]
        let panel = makeAssistantPanel(
            taskLister: taskStore,
            conversationHistoryStore: historyStore
        )

        panel.loadView()

        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("ambiguous actor output"))
        XCTAssertEqual(panel.assistantConclusionTextsForTesting, ["磁盘状态正常。"])
        XCTAssertEqual(panel.processGroupCountForTesting, 0)
    }

    func testAssistantHistoryKeepsOnlyLastOfThreeIdenticalConclusionsInUserTurn() throws {
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "查看 CPU"),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "CPU 负载正常。"),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "CPU 负载正常。"),
            makeHistoryRecord(runtimeID: "term_1", role: .assistant, content: "CPU 负载正常。")
        ]
        let panel = makeAssistantPanel(conversationHistoryStore: historyStore)

        panel.loadView()

        XCTAssertEqual(panel.assistantConclusionTextsForTesting, ["CPU 负载正常。"])
        XCTAssertEqual(panel.processGroupCountForTesting, 0)
    }

    func testAssistantHistoryKeepsOwnedBuiltInProcessWithoutConclusion() throws {
        let historyStore = RecordingAIConversationHistoryStore()
        historyStore.listedItems = [
            makeHistoryRecord(runtimeID: "term_1", role: .user, content: "观察日志"),
            makeHistoryRecord(
                runtimeID: "term_1",
                role: .terminal,
                content: "终端 · dev@example.com\n$ tail -f /var/log/messages\n仍在运行",
                requestID: "req-owned-process"
            )
        ]
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-owned-process",
                requestID: "req-owned-process",
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "tail -f /var/log/messages"
            )
        ]
        let panel = makeAssistantPanel(
            taskLister: taskStore,
            conversationHistoryStore: historyStore
        )

        panel.loadView()

        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("tail -f /var/log/messages"))
        XCTAssertEqual(panel.processGroupCountForTesting, 1)
    }

    func testAssistantPanelPersistsMessagesCommandCardStateAndExecutionSummary() throws {
        let historyStore = RecordingAIConversationHistoryStore()
        let executor = RecordingAgentCommandExecutor(eventsByCommand: [
            "df -h": [
                AgentTraceEvent(
                    requestID: "req-original",
                    state: .completed,
                    message: "本次命令已完成：Filesystem 42%",
                    redactedCommand: "df -h",
                    metadata: ["terminalOutputSummary": "Filesystem 42%"]
                )
            ]
        ])
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "建议查看磁盘。", proposedCommand: "df -h")
        )
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: executor,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            conversationHistoryStore: historyStore
        )

        panel.loadView()
        panel.setQuestionForTesting("磁盘占用")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        XCTAssertTrue(historyStore.appendedItems.contains { $0.role == .user && $0.content == "磁盘占用" })
        XCTAssertTrue(historyStore.appendedItems.contains { $0.role == .assistant && $0.content == "建议查看磁盘。" })
        XCTAssertTrue(historyStore.appendedItems.contains { item in
            item.role == .command
                && item.content.contains("命令卡片 · 待确认")
                && item.content.contains("$ df -h")
        })

        panel.skipCommandCardForTesting(at: 0)
        XCTAssertTrue(historyStore.appendedItems.contains { item in
            item.role == .command
                && item.content.contains("命令卡片 · 已跳过")
                && item.content.contains("$ df -h")
        })

        panel.runCommandCardForTesting(at: 0)
        XCTAssertTrue(historyStore.appendedItems.contains { item in
            item.role == .command
                && item.content.contains("命令卡片 · 已执行")
                && item.content.contains("$ df -h")
        })
        XCTAssertTrue(historyStore.appendedItems.contains { $0.role == .terminal && $0.content.contains("Filesystem 42%") })
        XCTAssertFalse(historyStore.appendedItems.contains { $0.role == .assistant && $0.content.contains("本次执行结果：Filesystem 42%") })
    }

    func testAssistantIgnoresEmptyQuestionAndSubmitsNonEmptyQuestionWithReturnKey() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "建议查看磁盘占用。", proposedCommand: "df -h")
        )
        let panel = makeAssistantPanel(provider: provider, settingsStore: makeSettingsStore(autoRunProposedCommands: false))

        panel.loadView()

        XCTAssertFalse(panel.askButtonEnabledForTesting)
        panel.performAskForTesting()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(panel.messageTextForTesting, L10n.AI.emptyQuestion)

        panel.setQuestionForTesting("  磁盘占用  ")
        XCTAssertTrue(panel.askButtonEnabledForTesting)
        panel.submitQuestionFromFieldForTesting()

        XCTAssertEqual(panel.questionTextForTesting, "")
        XCTAssertTrue(panel.transcriptTextForTesting.contains("磁盘占用"))
        XCTAssertFalse(panel.assistantTranscriptTextForTesting.contains("我先看一下当前终端上下文，再给你回复。"))
        XCTAssertTrue(waitUntil { provider.requests.map(\.question) == ["磁盘占用"] })
        XCTAssertEqual(provider.requests.map(\.question), ["磁盘占用"])
        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains("建议查看磁盘占用。") })
        XCTAssertEqual(panel.messageTextForTesting, "")
        XCTAssertTrue(panel.transcriptTextForTesting.contains("建议查看磁盘占用。"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("你："))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("AI："))
        XCTAssertEqual(panel.proposedCommandForTesting, "df -h")
        XCTAssertTrue(panel.executeButtonEnabledForTesting)
        XCTAssertFalse(panel.transcriptTextForTesting.contains("自动执行：df -h"))
    }

    func testAssistantContextShowsUnconfiguredOrModelModeFromSettings() throws {
        let settingsStore = makeUnconfiguredSettingsStore(autoRunProposedCommands: false)
        let panel = makeAssistantPanel(settingsStore: settingsStore)

        panel.loadView()
        panel.refreshForCurrentContext()

        XCTAssertTrue(panel.contextTextForTesting.contains(L10n.AI.modelMode))
        XCTAssertTrue(panel.contextTextForTesting.contains("mozheAPI · 未配置模型"))
        XCTAssertFalse(panel.contextTextForTesting.contains("Stacio 规则"))

        let provider = makeModelProvider(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            name: "OpenAI Compatible",
            modelIDs: ["qwen-plus"],
            defaultModelID: "qwen-plus"
        )
        try settingsStore.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        )

        XCTAssertTrue(panel.contextTextForTesting.contains(L10n.AI.modelMode))
        XCTAssertTrue(panel.contextTextForTesting.contains("qwen-plus"))
    }

    func testAssistantUnconfiguredProviderDisablesAskAndRejectsSubmissionWithoutRequest() {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "不应发送", proposedCommand: nil)
        )
        let store = makeUnconfiguredSettingsStore(autoRunProposedCommands: false)
        let panel = makeAssistantPanel(provider: provider, settingsStore: store)

        panel.loadView()

        XCTAssertEqual(panel.composerModelTitleForTesting, "mozheAPI · 未配置模型")
        XCTAssertEqual(panel.composerModelPickerModelTitlesForTesting, ["跟随全局默认"])
        XCTAssertTrue(panel.composerModelPickerReasoningTitlesForTesting.isEmpty)

        panel.setQuestionForTesting("检查磁盘")

        XCTAssertFalse(panel.askButtonEnabledForTesting)
        panel.submitQuestionFromFieldForTesting()
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(panel.questionTextForTesting, "检查磁盘")
        XCTAssertEqual(panel.messageTextForTesting, "请先在设置中配置供应商模型")
    }

    func testAssistantPanelHeaderShowsChatChromeWithoutDuplicateContextUsage() throws {
        let store = makeSettingsStore(
            autoRunProposedCommands: false,
            modelContextCharacterLimit: 100
        )
        let panel = makeAssistantPanel(
            settingsStore: store,
            recentTranscript: String(repeating: "x", count: 40)
        )

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
        panel.view.layoutSubtreeIfNeeded()

        let header = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.header"))
        let title = try XCTUnwrap(
            header.firstSubview(withIdentifier: "Stacio.AI.header.title") as? NSTextField
        )
        let status = try XCTUnwrap(
            header.firstSubview(withIdentifier: "Stacio.AI.header.status") as? NSTextField
        )
        let composerUsage = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.contextUsage")
        )

        XCTAssertEqual(title.stringValue, L10n.AI.assistant)
        XCTAssertTrue(status.stringValue.contains("就绪"))
        XCTAssertNil(header.firstSubview(withIdentifier: "Stacio.AI.header.contextUsage"))
        XCTAssertNil(header.firstSubview(withIdentifier: "Stacio.AI.header.contextBar"))
        XCTAssertTrue(composerUsage.toolTip?.contains("40%") == true)
        XCTAssertEqual(header.frame.height, 66, accuracy: 1)
    }

    func testAssistantLocalAgentModeHidesBuiltInContextUsageRing() throws {
        let panel = makeAssistantPanel(
            localAgentToolResolver: StaticLocalAgentToolResolver(paths: [.codex: "/tools/codex"])
        )

        panel.loadView()
        let contextRing = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.contextUsage")
        )

        XCTAssertFalse(contextRing.isHidden)

        panel.switchSurfaceModeForTesting("本地 Agent")

        XCTAssertTrue(contextRing.isHidden)
        XCTAssertTrue(panel.composerHiddenForTesting)

        panel.switchSurfaceModeForTesting("排查助手")

        XCTAssertFalse(contextRing.isHidden)
        XCTAssertFalse(panel.composerHiddenForTesting)
    }

    func testAssistantTranscriptRendersRoleBubbles() throws {
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "建议查看磁盘。", proposedCommand: nil)
            )
        )

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 380, height: 520)
        panel.setQuestionForTesting("磁盘占用")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains("建议查看磁盘。") })
        panel.view.layoutSubtreeIfNeeded()

        XCTAssertNotNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.userBubble"))
        let assistantBubble = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.assistantBubble")
        )
        let assistantContent = try XCTUnwrap(assistantBubble.subviews.first)
        XCTAssertEqual(assistantContent.frame.width, assistantBubble.bounds.width, accuracy: 1)
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.statusBubble"))
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.traceBubble"))
        let userText = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.userText") as? NSTextField
        )
        let assistantText = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.assistantText") as? NSTextField
        )
        XCTAssertTrue(userText.isSelectable)
        XCTAssertTrue(assistantText.isSelectable)
    }

    func testAssistantClearsInputAndStopsThinkingWhenProviderFails() throws {
        let panel = makeAssistantPanel(provider: ThrowingAIAssistantProvider(
            error: AIAssistantProviderError.invalidResponse
        ))

        panel.loadView()
        panel.setQuestionForTesting("你帮我看下这台服务器上有什么项目")
        panel.performAskForTesting()

        XCTAssertEqual(panel.questionTextForTesting, "")
        XCTAssertTrue(panel.transcriptTextForTesting.contains("你帮我看下这台服务器上有什么项目"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("你："))
        XCTAssertTrue(waitUntil { panel.statusTextForTesting == "" })
        XCTAssertEqual(panel.statusTextForTesting, "")
        XCTAssertFalse(panel.messageTextForTesting.contains("DecodingError"))
        XCTAssertTrue(panel.messageTextForTesting.contains("AI"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("请求失败"))
    }

    func testAssistantClearsInputImmediatelyWhileSlowProviderIsStillThinking() throws {
        let provider = DelayedAIAssistantProvider(
            response: AIAssistantResponse(message: "稍后返回", proposedCommand: nil),
            delay: 0.25
        )
        let panel = makeAssistantPanel(provider: provider)

        panel.loadView()
        panel.setQuestionForTesting("系统为什么卡")
        panel.performAskForTesting()

        XCTAssertEqual(panel.questionTextForTesting, "")
        XCTAssertTrue(panel.askButtonEnabledForTesting)
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, "停止当前 AI 请求")
        XCTAssertEqual(panel.statusTextForTesting, L10n.AI.thinking)
        XCTAssertTrue(panel.transcriptTextForTesting.contains("系统为什么卡"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("你："))
        XCTAssertFalse(panel.assistantTranscriptTextForTesting.contains("我先看一下当前终端上下文，再给你回复。"))
        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains("稍后返回") })
    }

    func testAssistantShowsRealtimeThinkingProgressWhileProviderIsWorking() throws {
        let provider = DelayedAIAssistantProvider(
            response: AIAssistantResponse(message: "稍后返回", proposedCommand: nil),
            delay: 0.25
        )
        let panel = makeAssistantPanel(provider: provider)

        panel.loadView()
        panel.setQuestionForTesting("系统为什么卡")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.statusTextForTesting.contains("我正在整理当前终端里的关键信息。")
                || panel.statusTextForTesting.contains("我正在组织回复。")
        })
        XCTAssertFalse(panel.transcriptTextForTesting.contains("我正在整理当前终端里的关键信息。"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("我正在组织回复。"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("正在准备终端上下文"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("AI 正在生成回复"))
        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains("稍后返回") })
    }

    func testAssistantExecutionShowsBusyAndFinishedStates() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-execute",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "pwd"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "执行 pwd", proposedCommand: "pwd")
            ),
            executionCoordinator: execution
        )

        panel.loadView()
        panel.setQuestionForTesting("当前目录")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { execution.requests.count == 1 })

        XCTAssertEqual(panel.statusTextForTesting, "命令已在终端执行，输出将实时显示")
        XCTAssertFalse(panel.executeButtonEnabledForTesting)
        XCTAssertEqual(execution.requests.count, 1)
        XCTAssertTrue(panel.transcriptTextForTesting.contains("终端 · dev@example.com"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("$ pwd"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("运行中 ·"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("pwd"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("执行："))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("命令已交给目标终端"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("必要时可以暂停、取消、接管或确认完成"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("agent-step-"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("running"))
        XCTAssertEqual(panel.commandCardCountForTesting, 0)
    }

    func testAssistantAutomaticallyRunsProposedCommandThroughAgentFlow() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-auto-run",
                state: .queued,
                message: "Stacio AI 已请求操作 dev@example.com",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-auto-run",
                state: .approved,
                message: "已按全局策略自动放行",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-auto-run",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "uptime"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "先看负载。", proposedCommand: "uptime")
            ),
            executionCoordinator: execution
        )

        panel.loadView()
        panel.setQuestionForTesting("这台机器卡吗")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { execution.requests.count == 1 })
        XCTAssertEqual(panel.commandCardCountForTesting, 0)
        XCTAssertFalse(panel.transcriptTextForTesting.contains("自动执行：uptime"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("准备写入终端：uptime"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("已加入执行队列"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("已确认，准备写入终端"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("运行中 ·"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("终端 · dev@example.com"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("$ uptime"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("uptime"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("执行："))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("命令已交给目标终端"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("req-auto-run"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("queued"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("approved"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("running"))
        guard case .runCommand(let run) = execution.requests.first?.action else {
            return XCTFail("expected run command")
        }
        XCTAssertEqual(run.target, .runtimeID("term_1"))
        XCTAssertEqual(run.command, "uptime")
    }

    func testAssistantAutoRunOnlyUsesFirstInitialCommandAndGetsNextCommandFromNewModelReply() throws {
        let provider = SequencedPanelAIAssistantProvider(responses: [
            AIAssistantResponse(
                message: "先看负载，再看磁盘。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly),
                    AgentCommandProposal(command: "df -h", explanation: "首轮第二条，不应直接执行。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "负载正常，改看 CPU 进程。",
                commandProposals: [
                    AgentCommandProposal(
                        command: "ps aux --sort=-%cpu | head -5",
                        explanation: "根据真实负载输出继续看进程。",
                        risk: .readOnly
                    )
                ]
            ),
            AIAssistantResponse(message: "进程也正常，完成。", commandProposals: [])
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：load average: 0.05",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "load average: 0.05"]
                )
            ],
            "ps aux --sort=-%cpu | head -5": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：PID CPU COMMAND\n1 0.1 launchd",
                    redactedCommand: "ps aux --sort=-%cpu | head -5",
                    metadata: ["terminalOutputSummary": "PID CPU COMMAND\n1 0.1 launchd"]
                )
            ]
        ])
        let panel = makeAssistantPanel(provider: provider, executionCoordinator: execution)

        panel.loadView()
        panel.setQuestionForTesting("检查这台机器")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            execution.commands == ["uptime", "ps aux --sort=-%cpu | head -5"]
                && panel.transcriptTextForTesting.contains("进程也正常，完成。")
        })
        XCTAssertFalse(execution.commands.contains("df -h"))
        XCTAssertEqual(provider.requests.count, 3)
        XCTAssertTrue(provider.requests[1].question.contains("load average: 0.05"))
        XCTAssertFalse(provider.requests[1].question.contains("df -h"))
        XCTAssertTrue(provider.requests[2].question.contains("PID CPU COMMAND"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("第 1 步：查看负载。"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("第 2 步：根据真实负载输出继续看进程。"))
    }

    func testAssistantAutoRunAppendsOnlyConciseFinalResult() throws {
        let provider = SequencedPanelAIAssistantProvider(responses: [
            AIAssistantResponse(
                message: "先看负载。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(message: "负载正常，不需要继续处理。", commandProposals: [])
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：load average: 0.05",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "load average: 0.05"]
                )
            ]
        ])
        let panel = makeAssistantPanel(provider: provider, executionCoordinator: execution)

        panel.loadView()
        panel.setQuestionForTesting("检查这台机器是否卡顿")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.assistantTranscriptTextForTesting.contains("负载正常，不需要继续处理。")
        })
        let assistantTranscript = panel.assistantTranscriptTextForTesting
        XCTAssertEqual(
            assistantTranscript.components(separatedBy: "负载正常，不需要继续处理。").count - 1,
            1
        )
        XCTAssertEqual(panel.statusTextForTesting, "")
        XCTAssertFalse(assistantTranscript.contains("任务完成"))
        XCTAssertFalse(assistantTranscript.contains("关键步骤"))
        XCTAssertFalse(assistantTranscript.contains("uptime"))
        XCTAssertFalse(assistantTranscript.contains("load average: 0.05"))
    }

    func testAssistantStreamingFinalResultReplacesProcessDraftAndAppearsOnce() {
        let conclusion = "CPU 当前使用率很低，系统运行正常。"
        let historyStore = RecordingAIConversationHistoryStore()
        let provider = SequencedStreamingPanelAIAssistantProvider(
            responses: [
                (
                    partials: ["先查看 CPU。"],
                    response: AIAssistantResponse(
                        message: "先查看 CPU。",
                        commandProposals: [
                            AgentCommandProposal(command: "top -bn1 | head -n 20", explanation: "查看 CPU。", risk: .readOnly)
                        ]
                    )
                ),
                (
                    partials: ["CPU 当前使用率很低，", "系统运行正常。"],
                    response: AIAssistantResponse(message: conclusion, commandProposals: [])
                )
            ]
        )
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "top -bn1 | head -n 20": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：98.9% idle",
                    redactedCommand: "top -bn1 | head -n 20",
                    metadata: ["terminalOutputSummary": "98.9% idle"]
                )
            ]
        ])
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: execution,
            conversationHistoryStore: historyStore
        )

        panel.loadView()
        panel.setQuestionForTesting("查看 CPU")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains(conclusion) })
        XCTAssertEqual(
            panel.assistantTranscriptTextForTesting.components(separatedBy: conclusion).count - 1,
            1
        )
        XCTAssertEqual(
            historyStore.appendedItems.filter { $0.role == .assistant }.map(\.content),
            [conclusion]
        )
        XCTAssertTrue(historyStore.appendedItems.contains {
            $0.role == .step && $0.content == "先查看 CPU。"
        })
        XCTAssertEqual(panel.statusTextForTesting, "")
    }

    func testAssistantAutoRunStopsWhenFirstStepFailsAndDoesNotAskForNextStep() throws {
        let provider = SequencedPanelAIAssistantProvider(responses: [
            AIAssistantResponse(
                message: "先看磁盘，再看负载。",
                commandProposals: [
                    AgentCommandProposal(command: "df -h", explanation: "查看磁盘。", risk: .readOnly),
                    AgentCommandProposal(command: "uptime", explanation: "失败后不应执行。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "不应请求下一步。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "不应执行。", risk: .readOnly)
                ]
            )
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "df -h": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .failed,
                    message: "执行失败：Permission denied",
                    redactedCommand: "df -h",
                    metadata: ["terminalOutputSummary": "Permission denied"]
                )
            ]
        ])
        let panel = makeAssistantPanel(provider: provider, executionCoordinator: execution)

        panel.loadView()
        panel.setQuestionForTesting("检查磁盘")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.transcriptTextForTesting.contains("执行失败") })
        XCTAssertEqual(execution.commands, ["df -h"])
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertFalse(execution.commands.contains("uptime"))
        XCTAssertTrue(panel.systemTranscriptTextForTesting.contains("执行失败：Permission denied"))
        XCTAssertFalse(panel.systemTranscriptTextForTesting.contains("关键步骤"))
        XCTAssertFalse(panel.systemTranscriptTextForTesting.contains("df -h"))
        XCTAssertTrue(panel.systemTranscriptTextForTesting.contains("Permission denied"))
    }

    func testAssistantStreamsVirtualTerminalOutputAndFinalResultIntoConversation() throws {
        let execution = StreamingRecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-streaming-terminal",
                state: .queued,
                message: "Stacio AI 已请求操作 dev@example.com",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-streaming-terminal",
                state: .approved,
                message: "已按全局策略自动放行",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-streaming-terminal",
                state: .running,
                message: "AI 独立任务输出：load average: 0.67",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "terminalOutputSummary": "load average: 0.67"
                ]
            ),
            AgentTraceEvent(
                requestID: "req-streaming-terminal",
                state: .completed,
                message: "AI 独立任务已完成：load average: 0.67",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "terminalOutputSummary": "load average: 0.67"
                ]
            )
        ])
        let taskStore = RecordingAgentTaskStore()
        taskStore.nextRequestID = "req-streaming-terminal"
        let panel = makeAssistantPanel(
            provider: SequencedPanelAIAssistantProvider(responses: [
                AIAssistantResponse(message: "结论会在执行后显示。", proposedCommand: "uptime"),
                AIAssistantResponse(message: "本次执行结果：load average: 0.67", commandProposals: [])
            ]),
            executionCoordinator: execution,
            taskRecorder: taskStore
        )

        panel.loadView()
        panel.setQuestionForTesting("这台机器卡吗")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.rawTranscriptTextForTesting.contains("终端 · dev@example.com")
                && panel.rawTranscriptTextForTesting.contains("$ uptime")
                && panel.rawTranscriptTextForTesting.contains("load average: 0.67")
                && panel.transcriptTextForTesting.contains("本次执行结果：load average: 0.67")
                && panel.processGroupSummaryTextsForTesting.first?.hasPrefix("已处理 ") == true
        })
        XCTAssertGreaterThan(panel.collapsedProcessEntryCountForTesting, 0)
        XCTAssertEqual(panel.processGroupCountForTesting, 1)
        XCTAssertNotNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.processGroup"))
        XCTAssertTrue(panel.processGroupSummaryTextsForTesting.first?.hasPrefix("已处理 ") == true)
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.systemBubble"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("虚拟终端输出："))
        XCTAssertFalse(panel.systemTranscriptTextForTesting.contains("本次执行结果：load average: 0.67"))
        XCTAssertEqual(
            panel.assistantTranscriptTextForTesting.components(separatedBy: "本次执行结果：load average: 0.67").count - 1,
            1
        )
        XCTAssertEqual(execution.streamingRequestIDs, execution.requests.map(\.id))
        XCTAssertTrue(execution.streamingRequestIDs.allSatisfy { $0.hasPrefix("agent-step-") })
    }

    func testAssistantAutoRunShowsProcessBeforeConclusionAndCollapsesWhenFinished() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-auto-finished",
                state: .queued,
                message: "Stacio AI 已请求操作 dev@example.com",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-auto-finished",
                state: .approved,
                message: "已按全局策略自动放行",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-auto-finished",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-auto-finished",
                state: .completed,
                message: "AI 独立任务已完成：load average: 0.01",
                redactedCommand: "uptime",
                metadata: ["executionMode": "backgroundTask"]
            )
        ])
        let panel = makeAssistantPanel(
            provider: SequencedPanelAIAssistantProvider(responses: [
                AIAssistantResponse(message: "先读取负载。", proposedCommand: "uptime"),
                AIAssistantResponse(message: "结论：负载正常。", commandProposals: [])
            ]),
            executionCoordinator: execution
        )

        panel.loadView()
        panel.setQuestionForTesting("这台机器卡吗")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.transcriptTextForTesting.contains("结论：负载正常。")
                && panel.collapsedProcessEntryCountForTesting > 0
                && panel.processGroupSummaryTextsForTesting.first?.hasPrefix("已处理 ") == true
        })
        let transcript = panel.transcriptTextForTesting
        let processIndex = try XCTUnwrap(transcript.range(of: "终端 · dev@example.com")?.lowerBound)
        let resultIndex = try XCTUnwrap(transcript.range(of: "结论：负载正常。")?.lowerBound)
        XCTAssertLessThan(processIndex, resultIndex)
        XCTAssertFalse(transcript.contains("关键步骤概要"))
        XCTAssertGreaterThan(panel.collapsedThinkingEntryCountForTesting, 0)
        XCTAssertEqual(panel.processGroupCountForTesting, 1)
        XCTAssertTrue(panel.processGroupSummaryTextsForTesting.first?.hasPrefix("已处理 ") == true)
        XCTAssertNotNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.processGroup"))
        XCTAssertNotNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.processDisclosure"))
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.systemBubble"))
        panel.expandAllProcessEntriesForTesting()
        XCTAssertEqual(panel.collapsedProcessEntryCountForTesting, 0)
        XCTAssertTrue(panel.transcriptTextForTesting.contains("$ uptime"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("load average: 0.01"))
        XCTAssertFalse(transcript.contains("已加入执行队列"))
        XCTAssertFalse(transcript.contains("已确认，准备写入终端"))
        XCTAssertFalse(transcript.contains("运行中 ·"))
        XCTAssertEqual(panel.taskControlTextForTesting, "")
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.taskWorkspace"))
    }

    func testAssistantShowsTerminalOutputInConversationWithoutTaskTimelineWorkspace() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-task",
                state: .queued,
                message: "Stacio AI 已请求操作 dev@example.com",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-task",
                state: .approved,
                message: "已按全局策略自动放行",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-task",
                state: .running,
                message: "AI 独立任务输出：load average: 0.42",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-task",
                state: .completed,
                message: "AI 独立任务已完成：load average: 0.42",
                redactedCommand: "uptime"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "查看系统负载", proposedCommand: "uptime")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("系统负载")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)

        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("终端 · dev@example.com"))
        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("$ uptime"))
        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("load average: 0.42"))
        XCTAssertGreaterThan(panel.collapsedProcessEntryCountForTesting, 0)
        XCTAssertEqual(panel.processGroupCountForTesting, 1)
        XCTAssertTrue(panel.processGroupSummaryTextsForTesting.first?.hasPrefix("已处理 ") == true)
        XCTAssertFalse(panel.taskControlTextForTesting.contains("任务时间线"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("req-task"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("queued"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("approved"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("running"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("completed"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("审计"))
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.taskWorkspace"))
    }

    func testAssistantConversationUsesStructuredTerminalOutputMetadata() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-task-metadata-output",
                state: .running,
                message: "终端实时输出已更新",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "terminalOutputSummary": "load average: 0.67"
                ]
            ),
            AgentTraceEvent(
                requestID: "req-task-metadata-output",
                state: .completed,
                message: "命令已完成",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "terminalOutputSummary": "load average: 0.67"
                ]
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "查看系统负载", proposedCommand: "uptime")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("系统负载")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)

        XCTAssertTrue(panel.transcriptTextForTesting.contains("终端 · dev@example.com"))
        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("load average: 0.67"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("输出摘要："))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("后台任务"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("req-task-metadata-output"))
    }

    func testAssistantConversationKeepsRealtimeOutputUpdatesWithDistinctMetadata() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-task-realtime-output",
                state: .running,
                message: "终端实时输出已更新",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "terminalOutputSummary": "phase 1"
                ]
            ),
            AgentTraceEvent(
                requestID: "req-task-realtime-output",
                state: .running,
                message: "终端实时输出已更新",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "terminalOutputSummary": "phase 2"
                ]
            ),
            AgentTraceEvent(
                requestID: "req-task-realtime-output",
                state: .completed,
                message: "命令已完成",
                redactedCommand: "uptime",
                metadata: ["executionMode": "backgroundTask"]
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "查看系统负载", proposedCommand: "uptime")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("系统负载")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)

        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("phase 2"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("phase 1"))
        XCTAssertGreaterThan(panel.collapsedProcessEntryCountForTesting, 0)
        XCTAssertEqual(panel.taskControlTextForTesting, "")
    }

    func testAssistantDoesNotRenderDismissibleTaskControlAfterTerminalState() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-task-dismiss",
                state: .running,
                message: "AI 独立任务输出：load average: 0.42",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-task-dismiss",
                state: .completed,
                message: "AI 独立任务已完成：load average: 0.42",
                redactedCommand: "uptime"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "查看系统负载", proposedCommand: "uptime")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("系统负载")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)

        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("load average: 0.42"))
        XCTAssertEqual(panel.taskControlTextForTesting, "")
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.taskWorkspace"))
        XCTAssertFalse(panel.taskPauseEnabledForTesting)
        XCTAssertFalse(panel.taskCancelEnabledForTesting)
        XCTAssertFalse(panel.taskTakeOverEnabledForTesting)

        panel.performTaskControlDismissForTesting()

        XCTAssertEqual(panel.taskControlTextForTesting, "")
    }

    func testAssistantUsesBackgroundTaskStatusInsteadOfGenericSentState() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-background-status",
                state: .approved,
                message: "已按全局策略自动放行",
                redactedCommand: "uptime"
            ),
            AgentTraceEvent(
                requestID: "req-background-status",
                state: .running,
                message: "独立任务已启动，输出将同步显示",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "sourceRuntimeID": "term_1",
                    "targetTitle": "dev@example.com"
                ]
            ),
            AgentTraceEvent(
                requestID: "req-background-status",
                state: .waitingForOutput,
                message: "已创建独立执行终端，等待输出",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "sourceRuntimeID": "term_1",
                    "taskRuntimeID": "agent_bg_7"
                ]
            ),
            AgentTraceEvent(
                requestID: "req-background-status",
                state: .completed,
                message: "AI 独立任务已完成：load average: 0.08",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "sourceRuntimeID": "term_1",
                    "taskRuntimeID": "agent_bg_7"
                ]
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "查看负载", proposedCommand: "uptime")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("系统负载")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)

        XCTAssertTrue(panel.statusTextForTesting.contains("AI 独立任务已完成"))
        XCTAssertTrue(panel.statusTextForTesting.contains("load average: 0.08"))
        XCTAssertFalse(panel.statusTextForTesting.contains(L10n.AI.sentToTerminal))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("终端 · dev@example.com"))
        XCTAssertTrue(panel.rawTranscriptTextForTesting.contains("load average: 0.08"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("agent_bg_7"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("后台任务"))
    }

    func testAssistantTaskControlRecordsCancelIntentInConversation() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-cancel",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "top"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "查看进程", proposedCommand: "top")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("看进程")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)
        panel.performTaskCancelForTesting()

        XCTAssertTrue(panel.taskControlTextForTesting.contains("已请求取消"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("未找到活动控制句柄"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("请在目标终端确认状态"))
        XCTAssertTrue(panel.statusTextForTesting.contains("已请求取消"))
    }

    func testAssistantTaskControlPausesThroughCoordinatorAndShowsTraceState() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-pause-real",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "tail -f /var/log/messages"
            )
        ])
        execution.pauseEvents["req-pause-real"] = AgentTraceEvent(
            requestID: "req-pause-real",
            state: .paused,
            message: "AI 后续自动动作已暂停；当前命令仍以目标终端输出为准。",
            redactedCommand: "tail -f /var/log/messages",
            metadata: ["control": "pause"]
        )
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "持续查看日志", proposedCommand: "tail -f /var/log/messages")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("看系统日志")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)
        panel.performTaskPauseForTesting()

        XCTAssertEqual(execution.pausedRequestIDs.count, 1)
        XCTAssertTrue(panel.taskControlTextForTesting.contains("AI 后续自动动作已暂停"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("paused"))
        XCTAssertTrue(panel.statusTextForTesting.contains("AI 后续自动动作已暂停"))
        XCTAssertFalse(panel.taskPauseEnabledForTesting)
        XCTAssertFalse(panel.taskCancelEnabledForTesting)
    }

    func testAssistantTaskControlManualConfirmCompletesAmbiguousVisibleStepWithoutTerminalControl() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-manual-confirm",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "tail -f /var/log/messages",
                metadata: ["executionMode": "visibleTerminal"]
            ),
            AgentTraceEvent(
                requestID: "req-manual-confirm",
                state: .waitingForOutput,
                message: "这条命令可能仍在运行，Stacio 不会根据静默输出自动判定完成；请手动停止、确认或接管。",
                redactedCommand: "tail -f /var/log/messages",
                metadata: [
                    "executionMode": "visibleTerminal",
                    "completionConfidence": "manualRequired"
                ]
            )
        ])
        execution.confirmEvents["req-manual-confirm"] = AgentTraceEvent(
            requestID: "req-manual-confirm",
            state: .completed,
            message: "已确认本步结束。",
            redactedCommand: "tail -f /var/log/messages",
            metadata: [
                "executionMode": "visibleTerminal",
                "completionConfidence": "userConfirmed",
                "completionReason": "userConfirmed"
            ]
        )
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "持续查看日志", proposedCommand: "tail -f /var/log/messages")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("看系统日志")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)
        XCTAssertTrue(panel.taskConfirmCompleteEnabledForTesting)
        panel.performTaskConfirmCompleteForTesting()

        XCTAssertTrue(panel.transcriptTextForTesting.contains("已确认本步结束"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("已确认本步结束"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("不会再把后续混入输出归入本步结果"))
        XCTAssertEqual(panel.statusTextForTesting, "已确认本步结束。")
        XCTAssertFalse(panel.taskConfirmCompleteEnabledForTesting)
        XCTAssertFalse(panel.taskPauseEnabledForTesting)
        XCTAssertFalse(panel.taskCancelEnabledForTesting)
        XCTAssertFalse(panel.taskTakeOverEnabledForTesting)
        XCTAssertEqual(execution.confirmedRequestIDs.count, 1)
        XCTAssertEqual(execution.pausedRequestIDs, [])
        XCTAssertEqual(execution.cancelledRequestIDs, [])
        XCTAssertEqual(execution.takenOverRequestIDs, [])
    }

    func testAssistantTaskControlCancelsBackgroundTaskThroughCoordinator() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-cancel-real",
                state: .running,
                message: "独立任务已启动，输出将同步显示",
                redactedCommand: "sleep 60",
                metadata: [
                    "executionMode": "backgroundTask",
                    "taskRuntimeID": "agent_bg_1"
                ]
            )
        ])
        execution.cancelEvents["req-cancel-real"] = AgentTraceEvent(
            requestID: "req-cancel-real",
            state: .cancelled,
            message: "AI 独立任务已取消。",
            redactedCommand: "sleep 60",
            metadata: [
                "executionMode": "backgroundTask",
                "taskRuntimeID": "agent_bg_1",
                "control": "cancel"
            ]
        )
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "准备执行", proposedCommand: "sleep 60")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("跑一个后台任务")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)
        panel.performTaskCancelForTesting()

        XCTAssertEqual(execution.cancelledRequestIDs.count, 1)
        XCTAssertTrue(panel.taskControlTextForTesting.contains("AI 独立任务已取消"))
        XCTAssertTrue(panel.statusTextForTesting.contains("AI 独立任务已取消"))
    }

    func testAssistantTaskControlShowsVisibleTerminalCancelInterrupt() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-visible-cancel-real",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "tail -f /var/log/messages",
                metadata: ["executionMode": "visibleTerminal"]
            )
        ])
        execution.cancelEvents["req-visible-cancel-real"] = AgentTraceEvent(
            requestID: "req-visible-cancel-real",
            state: .cancelled,
            message: "已向可见终端发送中断；输出仍以目标终端为准。",
            redactedCommand: "tail -f /var/log/messages",
            metadata: [
                "executionMode": "visibleTerminal",
                "control": "cancel"
            ]
        )
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "准备跟踪日志", proposedCommand: "tail -f /var/log/messages")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("跟踪日志")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)
        panel.performTaskCancelForTesting()

        XCTAssertEqual(execution.cancelledRequestIDs.count, 1)
        XCTAssertTrue(panel.taskControlTextForTesting.contains("已向可见终端发送中断"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("cancelled"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("控制状态："))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("已取消后台独立任务"))
        XCTAssertTrue(panel.statusTextForTesting.contains("已向可见终端发送中断"))
    }

    func testAssistantTaskControlTakeOverThroughCoordinatorAndStopsAIControls() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-takeover-real",
                state: .running,
                message: "独立任务已启动，输出将同步显示",
                redactedCommand: "sleep 60",
                metadata: [
                    "executionMode": "backgroundTask",
                    "taskRuntimeID": "agent_bg_2"
                ]
            )
        ])
        execution.takeOverEvents["req-takeover-real"] = AgentTraceEvent(
            requestID: "req-takeover-real",
            state: .takenOver,
            message: "任务已切换为人工接管；AI 不再继续自动执行。",
            redactedCommand: "sleep 60",
            metadata: [
                "executionMode": "backgroundTask",
                "taskRuntimeID": "agent_bg_2",
                "control": "takeover"
            ]
        )
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "准备执行", proposedCommand: "sleep 60")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("跑后台任务")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)
        panel.performTaskTakeOverForTesting()

        XCTAssertEqual(execution.takenOverRequestIDs.count, 1)
        XCTAssertTrue(panel.taskControlTextForTesting.contains("人工接管"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("takenOver"))
        XCTAssertTrue(panel.statusTextForTesting.contains("人工接管"))
        XCTAssertFalse(panel.taskPauseEnabledForTesting)
        XCTAssertFalse(panel.taskCancelEnabledForTesting)
        XCTAssertFalse(panel.taskTakeOverEnabledForTesting)
    }

    func testAssistantTaskControlShowsVisibleTerminalTakeOverControlStatus() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-visible-takeover-real",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "tail -f /var/log/messages",
                metadata: ["executionMode": "visibleTerminal"]
            )
        ])
        execution.takeOverEvents["req-visible-takeover-real"] = AgentTraceEvent(
            requestID: "req-visible-takeover-real",
            state: .takenOver,
            message: "可见终端已切换为人工接管；AI 不再继续自动执行。",
            redactedCommand: "tail -f /var/log/messages",
            metadata: [
                "executionMode": "visibleTerminal",
                "control": "takeover"
            ]
        )
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "准备跟踪日志", proposedCommand: "tail -f /var/log/messages")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("跟踪日志")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)
        panel.performTaskTakeOverForTesting()

        XCTAssertEqual(execution.takenOverRequestIDs.count, 1)
        XCTAssertTrue(panel.taskControlTextForTesting.contains("可见终端已切换为人工接管"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("takenOver"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("控制状态："))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("后台独立任务"))
        XCTAssertTrue(panel.statusTextForTesting.contains("可见终端已切换为人工接管"))
        XCTAssertFalse(panel.taskPauseEnabledForTesting)
        XCTAssertFalse(panel.taskCancelEnabledForTesting)
        XCTAssertFalse(panel.taskTakeOverEnabledForTesting)
    }

    func testAssistantShowsFailedTraceEventInsteadOfSentStatus() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-background-unavailable",
                state: .failed,
                message: "AI 独立任务失败：当前终端暂不支持 AI 独立任务执行。",
                redactedCommand: "uptime"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "执行 uptime", proposedCommand: "uptime")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("系统负载")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })
        panel.runCommandCardForTesting(at: 0)

        XCTAssertTrue(panel.statusTextForTesting.contains("暂不支持 AI 独立任务执行"))
        XCTAssertFalse(panel.statusTextForTesting.contains(L10n.AI.sentToTerminal))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("执行失败"))
    }

    func testAssistantKeepsFailedCommandCardAvailableForEditAndRetry() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-background-unavailable",
                state: .failed,
                message: "AI 独立任务失败：当前终端暂不支持 AI 独立任务执行。",
                redactedCommand: "uptime"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "执行 uptime", proposedCommand: "uptime")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("系统负载")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)

        XCTAssertEqual(panel.commandCardCountForTesting, 1)
        XCTAssertTrue(panel.commandCardTextForTesting(at: 0).contains("重新运行"))
        XCTAssertTrue(panel.commandCardTextForTesting(at: 0).contains("uptime"))
        XCTAssertTrue(panel.executeButtonEnabledForTesting)
    }

    func testAssistantShowsCommandCardAndWaitsForUserRunBeforeExecution() throws {
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "req-auto",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "mkdir -p /opt/test"
            )
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "准备创建目录。", proposedCommand: "mkdir -p /opt/test")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("创建测试目录")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })
        XCTAssertEqual(execution.requests.count, 0)
        XCTAssertEqual(panel.statusTextForTesting, "")
        XCTAssertFalse(panel.transcriptTextForTesting.contains("自动执行"))
        XCTAssertEqual(panel.proposedCommandForTesting, "mkdir -p /opt/test")

        panel.runCommandCardForTesting(at: 0)

        XCTAssertEqual(panel.statusTextForTesting, L10n.AI.sentToTerminal)
        XCTAssertEqual(panel.commandCardCountForTesting, 0)
        guard case .runCommand(let run) = execution.requests.first?.action else {
            return XCTFail("expected run command")
        }
        XCTAssertEqual(run.command, "mkdir -p /opt/test")
    }

    func testAssistantClearsInputAndShowsPendingStateImmediatelyAfterSend() throws {
        let panel = makeAssistantPanel(
            provider: DelayedAIAssistantProvider(
                response: AIAssistantResponse(message: "稍后返回", proposedCommand: nil),
                delay: 0.08
            )
        )

        panel.loadView()
        panel.setQuestionForTesting("  服务器无响应  ")
        XCTAssertTrue(panel.askButtonEnabledForTesting)

        panel.performAskForTesting()

        XCTAssertEqual(panel.questionTextForTesting, "")
        XCTAssertEqual(panel.statusTextForTesting, L10n.AI.thinking)
        XCTAssertTrue(panel.askButtonEnabledForTesting)
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, "停止当前 AI 请求")
        XCTAssertTrue(panel.transcriptTextForTesting.contains("服务器无响应"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("你："))

        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains("稍后返回") })
        XCTAssertEqual(panel.statusTextForTesting, "")
        XCTAssertFalse(panel.askButtonEnabledForTesting)
    }

    func testAssistantPanelSelectsTargetRuntimeFromPicker() throws {
        var requestedRuntimeIDs: [String?] = []
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "执行", proposedCommand: "pwd")
        )
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: provider,
                executionCoordinator: RecordingAgentCommandExecutor()
            ),
            contextProvider: { runtimeID in
                requestedRuntimeIDs.append(runtimeID)
                return AITerminalContext(
                    runtimeID: runtimeID ?? "term_current",
                    title: runtimeID == "term_remote" ? "deploy@example.com" : "本地",
                    currentDirectory: runtimeID == "term_remote" ? "/srv/app" : "/Users/mac",
                    recentTranscript: ""
                )
            },
            terminalSessionProvider: {
                [
                    AgentTerminalSessionSummary(
                        runtimeID: "term_current",
                        title: "本地",
                        kind: "local",
                        environment: "development",
                        isCurrent: true,
                        currentDirectory: "/Users/mac",
                        subtitle: "local · /Users/mac"
                    ),
                    AgentTerminalSessionSummary(
                        runtimeID: "term_remote",
                        title: "deploy@example.com",
                        kind: "ssh",
                        environment: "development",
                        isCurrent: false,
                        currentDirectory: "/srv/app",
                        subtitle: "ssh · /srv/app"
                    )
                ]
            },
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.selectTargetRuntimeForTesting("term_remote")
        panel.setQuestionForTesting("当前目录")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.requests.first?.context.runtimeID == "term_remote" })
        XCTAssertEqual(provider.requests.first?.context.runtimeID, "term_remote")
        XCTAssertTrue(panel.contextTextForTesting.contains("deploy@example.com"))
        XCTAssertEqual(panel.targetTitleForTesting, "deploy@example.com")
        XCTAssertTrue(requestedRuntimeIDs.contains("term_remote"))
    }

    func testAssistantFallsBackToCurrentTerminalWhenSelectedRuntimeDisappears() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "当前终端可用", proposedCommand: nil)
        )
        var contexts: [String: AITerminalContext] = [
            "term_current": AITerminalContext(
                runtimeID: "term_current",
                title: "本地",
                currentDirectory: "/Users/mac",
                recentTranscript: ""
            ),
            "term_remote": AITerminalContext(
                runtimeID: "term_remote",
                title: "deploy@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            )
        ]
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: provider,
                executionCoordinator: RecordingAgentCommandExecutor()
            ),
            contextProvider: { runtimeID in
                if let runtimeID {
                    return contexts[runtimeID]
                }
                return contexts["term_current"]
            },
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.selectTargetRuntimeForTesting("term_remote")
        contexts.removeValue(forKey: "term_remote")
        panel.setQuestionForTesting("还在吗")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.requests.first?.context.runtimeID == "term_current" })
        XCTAssertEqual(panel.targetTitleForTesting, "本地")
        XCTAssertTrue(panel.contextTextForTesting.contains("本地"))
    }

    func testTargetPickerSelectsRuntimeIDFromSessionList() throws {
        var selectedRuntimeID: String?
        let picker = AITargetPickerViewController(
            sessions: [
                AgentTerminalSessionSummary(
                    runtimeID: "term_current",
                    title: "本地",
                    kind: "local",
                    environment: "development",
                    isCurrent: true,
                    currentDirectory: "/Users/mac",
                    subtitle: "local · /Users/mac"
                ),
                AgentTerminalSessionSummary(
                    runtimeID: "term_remote",
                    title: "deploy@example.com",
                    kind: "ssh",
                    environment: "development",
                    isCurrent: false,
                    currentDirectory: "/srv/app",
                    subtitle: "ssh · /srv/app"
                )
            ]
        )
        picker.onSelectRuntimeID = { runtimeID in
            selectedRuntimeID = runtimeID
        }

        picker.loadView()
        picker.selectRuntimeForTesting("term_remote")

        XCTAssertEqual(selectedRuntimeID, "term_remote")
    }

    func testTargetPickerFiltersByTitleKindEnvironmentAndDirectoryWithEmptyState() throws {
        let picker = AITargetPickerViewController(
            sessions: [
                AgentTerminalSessionSummary(
                    runtimeID: "term_background",
                    title: "ops@example.com",
                    kind: "ssh",
                    environment: "production",
                    isCurrent: false,
                    currentDirectory: "/opt/ops",
                    subtitle: "ssh · /opt/ops"
                ),
                AgentTerminalSessionSummary(
                    runtimeID: "term_current",
                    title: "本地",
                    kind: "local",
                    environment: "development",
                    isCurrent: true,
                    currentDirectory: "/Users/mac/project",
                    subtitle: "local · /Users/mac/project"
                ),
                AgentTerminalSessionSummary(
                    runtimeID: "term_remote",
                    title: "deploy@example.com",
                    kind: "ssh",
                    environment: "staging",
                    isCurrent: false,
                    currentDirectory: "/srv/app",
                    subtitle: "ssh · /srv/app"
                )
            ]
        )

        picker.loadView()

        XCTAssertEqual(picker.visibleRuntimeIDsForTesting, ["term_current", "term_background", "term_remote"])
        XCTAssertTrue(picker.summaryTextForTesting.contains("3"))

        picker.setSearchQueryForTesting("srv")

        XCTAssertEqual(picker.visibleRuntimeIDsForTesting, ["term_remote"])
        XCTAssertTrue(picker.visibleRowTextForTesting(at: 0).contains("deploy@example.com"))
        XCTAssertTrue(picker.visibleRowTextForTesting(at: 0).contains("/srv/app"))
        XCTAssertTrue(picker.summaryTextForTesting.contains("1"))
        XCTAssertFalse(picker.emptyStateIsVisibleForTesting)

        picker.setSearchQueryForTesting("production")

        XCTAssertEqual(picker.visibleRuntimeIDsForTesting, ["term_background"])

        picker.setSearchQueryForTesting("no-match")

        XCTAssertTrue(picker.visibleRuntimeIDsForTesting.isEmpty)
        XCTAssertTrue(picker.emptyStateIsVisibleForTesting)
        XCTAssertEqual(picker.emptyStateTextForTesting, L10n.AI.noMatchingTargets)
    }

    func testAssistantPanelCollapseCallbackRunsFromButtonAndEscape() throws {
        var collapseCount = 0
        let panel = makeAssistantPanel()
        panel.onCollapse = {
            collapseCount += 1
        }

        panel.loadView()
        panel.performCollapseForTesting()
        _ = panel.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertEqual(collapseCount, 2)
    }

    func testAssistantShowsStructuredCommandProposalUntilUserRunsIt() throws {
        let execution = RecordingAgentCommandExecutor()
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(
                    message: "建议查看系统负载。",
                    commandProposals: [
                        AgentCommandProposal(
                            id: "proposal-1",
                            command: "uptime",
                            explanation: "查看系统负载。",
                            risk: .readOnly,
                            state: .proposed
                        )
                    ]
                )
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("机器卡吗")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })
        XCTAssertEqual(execution.requests.count, 0)
        XCTAssertEqual(panel.proposedCommandForTesting, "uptime")

        panel.runCommandCardForTesting(at: 0)

        guard case .runCommand(let run) = execution.requests.first?.action else {
            return XCTFail("expected run command")
        }
        XCTAssertEqual(run.command, "uptime")
    }

    func testAssistantCommandCardCopiesEditedCommandToPasteboard() throws {
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "建议查看服务。", proposedCommand: "systemctl status nginx")
            ),
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )
        NSPasteboard.general.clearContents()

        panel.loadView()
        panel.setQuestionForTesting("服务状态")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.editCommandCardForTesting(at: 0, command: "systemctl status sshd")
        panel.copyCommandCardForTesting(at: 0)

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "systemctl status sshd")
    }

    func testAssistantCommandCardRunsEditedCommandAndReclassifiesSkipRisk() throws {
        let execution = RecordingAgentCommandExecutor()
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "建议查看服务。", proposedCommand: "systemctl status nginx")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("服务状态")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.editCommandCardForTesting(at: 0, command: "systemctl restart nginx")
        panel.skipCommandCardForTesting(at: 0)
        XCTAssertTrue(panel.statusTextForTesting.contains("网络"))
        XCTAssertTrue(panel.statusTextForTesting.contains("systemctl restart nginx"))

        panel.editCommandCardForTesting(at: 0, command: "systemctl status nginx")
        panel.runCommandCardForTesting(at: 0)

        guard case .runCommand(let run) = execution.requests.first?.action else {
            return XCTFail("expected run command")
        }
        XCTAssertEqual(run.command, "systemctl status nginx")
    }

    func testAssistantRecordsTaskHistoryWhenResponseContainsProposals() throws {
        let taskStore = RecordingAgentTaskStore()
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(
                    message: "建议查看容器。",
                    commandProposals: [
                        AgentCommandProposal(
                            id: "proposal-docker",
                            command: "docker ps",
                            explanation: "列出容器。",
                            risk: .readOnly,
                            state: .proposed
                        )
                    ]
                )
            ),
            executionCoordinator: RecordingAgentCommandExecutor(),
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskRecorder: taskStore
        )

        panel.loadView()
        panel.setQuestionForTesting("看看容器")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { taskStore.records.count == 1 })
        XCTAssertEqual(taskStore.records[0].requestID.isEmpty, false)
        XCTAssertEqual(taskStore.records[0].session.targetRuntimeID, "term_1")
        XCTAssertEqual(taskStore.records[0].session.targetTitle, "dev@example.com")
        XCTAssertEqual(taskStore.records[0].session.state, .awaitingUser)
        XCTAssertEqual(taskStore.records[0].session.proposals.map(\.command), ["docker ps"])
        XCTAssertEqual(taskStore.records[0].userPrompt, "看看容器")
        XCTAssertEqual(taskStore.records[0].assistantMessage, "建议查看容器。")
    }

    func testAssistantExecutesProposalWithRecordedTaskRequestID() throws {
        let taskStore = RecordingAgentTaskStore()
        let execution = RecordingAgentCommandExecutor(eventsByRequestID: [
            "req-recorded-1": [
                AgentTraceEvent(
                    requestID: "req-recorded-1",
                    state: .running,
                    message: "独立任务已启动，输出将同步显示",
                    redactedCommand: "docker ps",
                    metadata: ["executionMode": "backgroundTask"]
                )
            ]
        ])
        taskStore.nextRequestID = "req-recorded-1"
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(
                    message: "建议查看容器。",
                    commandProposals: [
                        AgentCommandProposal(
                            id: "proposal-docker",
                            command: "docker ps",
                            explanation: "列出容器。",
                            risk: .readOnly,
                            state: .proposed
                        )
                    ]
                )
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskRecorder: taskStore
        )

        panel.loadView()
        panel.setQuestionForTesting("看看容器")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { taskStore.records.count == 1 })
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })

        panel.runCommandCardForTesting(at: 0)

        XCTAssertEqual(taskStore.records.first?.requestID, "req-recorded-1")
        XCTAssertEqual(execution.requests.first?.id, "req-recorded-1")
        XCTAssertTrue(panel.transcriptTextForTesting.contains("$ docker ps"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("命令已交给目标终端"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("req-recorded-1"))
    }

    func testAssistantPanelLoadsRecentTaskHistoryFromStore() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            AgentTaskSessionRecord(
                id: "task-recent",
                requestId: "req-recent",
                actorKind: "builtInAI",
                actorName: "Stacio AI",
                targetRuntimeId: "term_1",
                targetTitle: "dev@example.com",
                state: "completed",
                userPrompt: "看容器",
                assistantMessage: "建议查看容器。",
                createdAt: "2026-06-06T00:00:00Z",
                updatedAt: "2026-06-06T00:01:00Z",
                proposals: [
                    AgentTaskProposalRecord(
                        id: "proposal-recent",
                        command: "docker ps",
                        explanation: "列出容器",
                        risk: "readOnly",
                        state: "completed",
                        sortOrder: 0,
                        createdAt: "2026-06-06T00:00:00Z",
                        updatedAt: "2026-06-06T00:01:00Z"
                    )
                ]
            )
        ]
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskRecorder: taskStore,
            taskLister: taskStore
        )

        panel.loadView()

        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("最近任务"))
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("dev@example.com"))
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("completed"))
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("docker ps"))
        XCTAssertEqual(taskStore.listLimits, [24])
    }

    func testAssistantPanelExcludesExternalCLIFromRecentTaskHistory() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-external",
                requestID: "req-external",
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "free -h",
                actorKind: AgentActorKind.externalCLI.rawValue,
                actorName: "codex"
            ),
            makeAgentTaskSessionRecord(
                id: "task-built-in",
                requestID: "req-built-in",
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "docker ps"
            )
        ]
        let panel = makeAssistantPanel(taskLister: taskStore)

        panel.loadView()

        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("docker ps"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("free -h"))
    }

    func testAssistantPanelHidesRecentTaskHistoryWhenNoTerminalContext() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-other-terminal",
                requestID: "req-other-terminal",
                runtimeID: "term_other",
                title: "prod@example.com",
                command: "docker compose version"
            )
        ]
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskLister: taskStore,
            contextProvider: { _ in nil }
        )

        panel.loadView()

        XCTAssertTrue(panel.taskHistoryHiddenForTesting)
        XCTAssertEqual(panel.taskHistoryTextForTesting, "")
        XCTAssertEqual(taskStore.listLimits, [])
    }

    func testAssistantPanelDoesNotShowRecentHistoryWhenContextVanishesDuringRefresh() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-stale-terminal",
                requestID: "req-stale-terminal",
                runtimeID: "term_stale",
                title: "stale@example.com",
                command: "docker compose version"
            )
        ]
        var contextProviderCalls = 0
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskLister: taskStore,
            contextProvider: { _ in
                contextProviderCalls += 1
                guard contextProviderCalls > 2 else { return nil }
                return AITerminalContext(
                    runtimeID: "term_stale",
                    title: "stale@example.com",
                    currentDirectory: "/srv/stale",
                    recentTranscript: "old output"
                )
            }
        )

        panel.loadView()

        XCTAssertEqual(panel.contextTextForTesting, L10n.AI.noTerminal)
        XCTAssertTrue(panel.taskHistoryHiddenForTesting)
        XCTAssertEqual(panel.taskHistoryTextForTesting, "")
        XCTAssertEqual(taskStore.listLimits, [])
    }

    func testAssistantPanelFiltersRecentTaskHistoryToCurrentTerminalContext() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-prod",
                requestID: "req-prod",
                runtimeID: "term_prod",
                title: "prod@example.com",
                command: "docker compose version"
            ),
            makeAgentTaskSessionRecord(
                id: "task-dev",
                requestID: "req-dev",
                runtimeID: "term_dev",
                title: "dev@example.com",
                command: "docker ps"
            )
        ]
        let contexts: [String: AITerminalContext] = [
            "term_dev": AITerminalContext(
                runtimeID: "term_dev",
                title: "dev@example.com",
                currentDirectory: "/srv/dev",
                recentTranscript: ""
            ),
            "term_prod": AITerminalContext(
                runtimeID: "term_prod",
                title: "prod@example.com",
                currentDirectory: "/srv/prod",
                recentTranscript: ""
            )
        ]
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskLister: taskStore,
            contextProvider: { runtimeID in
                if let runtimeID {
                    return contexts[runtimeID]
                }
                return contexts["term_dev"]
            }
        )

        panel.loadView()

        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("dev@example.com"))
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("docker ps"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("prod@example.com"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("docker compose version"))

        panel.selectTargetRuntimeForTesting("term_prod")

        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("prod@example.com"))
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("docker compose version"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("dev@example.com"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("docker ps"))
    }

    func testAssistantPanelScansBeyondGlobalTopThreeForCurrentTerminalHistory() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            makeAgentTaskSessionRecord(
                id: "task-other-1",
                requestID: "req-other-1",
                runtimeID: "term_other_1",
                title: "other-1@example.com",
                command: "uptime"
            ),
            makeAgentTaskSessionRecord(
                id: "task-other-2",
                requestID: "req-other-2",
                runtimeID: "term_other_2",
                title: "other-2@example.com",
                command: "df -h"
            ),
            makeAgentTaskSessionRecord(
                id: "task-other-3",
                requestID: "req-other-3",
                runtimeID: "term_other_3",
                title: "other-3@example.com",
                command: "free -m"
            ),
            makeAgentTaskSessionRecord(
                id: "task-dev",
                requestID: "req-dev",
                runtimeID: "term_1",
                title: "dev@example.com",
                command: "docker ps"
            )
        ]
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskLister: taskStore
        )

        panel.loadView()

        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("dev@example.com"))
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("docker ps"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("other-1@example.com"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("other-2@example.com"))
        XCTAssertFalse(panel.taskHistoryTextForTesting.contains("other-3@example.com"))
    }

    func testAssistantPanelKeepsRecentTasksBeforeCurrentConversation() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            AgentTaskSessionRecord(
                id: "task-recent",
                requestId: "req-recent",
                actorKind: "builtInAI",
                actorName: "Stacio AI",
                targetRuntimeId: "term_1",
                targetTitle: "dev@example.com",
                state: "completed",
                userPrompt: "看容器",
                assistantMessage: "建议查看容器。",
                createdAt: "2026-06-06T00:00:00Z",
                updatedAt: "2026-06-06T00:01:00Z",
                proposals: []
            )
        ]
        let panel = makeAssistantPanel(
            provider: DelayedAIAssistantProvider(
                response: AIAssistantResponse(message: "你好。", proposedCommand: nil),
                delay: 0.05
            ),
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskLister: taskStore
        )

        panel.loadView()
        panel.setQuestionForTesting("你好")
        panel.performAskForTesting()

        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("最近任务"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("你好"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("你："))
        let order = panel.transcriptContentOrderForTesting
        let historyIndex = try XCTUnwrap(order.firstIndex(of: "taskHistory"))
        let transcriptIndex = try XCTUnwrap(order.firstIndex(of: "transcript"))
        XCTAssertLessThan(historyIndex, transcriptIndex)
    }

    func testAssistantPanelDoesNotExposeOldRecentTaskHistoryWorkspace() throws {
        let taskStore = RecordingAgentTaskStore()
        taskStore.listedSessions = [
            AgentTaskSessionRecord(
                id: "task-recent-open",
                requestId: "req-recent-open",
                actorKind: "builtInAI",
                actorName: "Stacio AI",
                targetRuntimeId: "term_1",
                targetTitle: "prod@example.com",
                state: "completed",
                userPrompt: "查看容器",
                assistantMessage: "建议查看容器状态。",
                createdAt: "2026-06-06T00:00:00Z",
                updatedAt: "2026-06-06T00:01:00Z",
                proposals: [
                    AgentTaskProposalRecord(
                        id: "proposal-history",
                        command: "docker ps --format json",
                        explanation: "列出容器",
                        risk: "readOnly",
                        state: "completed",
                        sortOrder: 0,
                        createdAt: "2026-06-06T00:00:00Z",
                        updatedAt: "2026-06-06T00:01:00Z"
                    )
                ]
            )
        ]
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            taskRecorder: taskStore,
            taskLister: taskStore
        )

        panel.loadView()
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("prod@example.com"))
        XCTAssertTrue(panel.taskHistoryTextForTesting.contains("docker ps --format json"))
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.taskHistory.open.0"))
        XCTAssertEqual(taskStore.listedRequestIDs, [])
        XCTAssertEqual(panel.taskControlTextForTesting, "")
        XCTAssertFalse(panel.taskPauseEnabledForTesting)
        XCTAssertFalse(panel.taskCancelEnabledForTesting)
        XCTAssertFalse(panel.taskTakeOverEnabledForTesting)
    }

    func testAssistantClearsCommandCardAfterUserRunsProposal() throws {
        let execution = RecordingAgentCommandExecutor()
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "查看磁盘", proposedCommand: "df -h")
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("磁盘")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })
        panel.runCommandCardForTesting(at: 0)

        XCTAssertEqual(execution.requests.count, 1)
        XCTAssertEqual(panel.commandCardCountForTesting, 0)
        XCTAssertTrue(panel.transcriptTextForTesting.contains("准备把命令交给目标终端。"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("终端 · dev@example.com"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("$ df -h"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("准备写入终端：df -h"))
    }

    func testAssistantPanelUsesBottomComposerLayout() throws {
        let panel = makeAssistantPanel()

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        panel.view.layoutSubtreeIfNeeded()

        let composer = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.composer"))
        let questionField = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.question") as? NSTextField
        )
        let conversation = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.conversation"))
        let header = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.header"))
        let scrollView = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcriptScroll"))

        XCTAssertEqual(composer.frame.minY, 14, accuracy: 1)
        XCTAssertGreaterThanOrEqual(composer.frame.height, 72)
        XCTAssertGreaterThan(conversation.frame.minY, composer.frame.maxY)
        XCTAssertEqual(header.frame.height, 66, accuracy: 1)
        XCTAssertGreaterThan(scrollView.frame.height, header.frame.height)
        XCTAssertGreaterThanOrEqual(questionField.frame.height, 44)
        XCTAssertGreaterThanOrEqual(questionField.frame.width, 320)
    }

    func testAssistantPanelKeepsComposerCompactOnTallInitialLayout() throws {
        let panel = makeAssistantPanel()

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        panel.view.layoutSubtreeIfNeeded()

        let composer = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.composer"))
        let scrollView = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcriptScroll"))

        XCTAssertEqual(composer.frame.minY, 14, accuracy: 1)
        XCTAssertLessThanOrEqual(composer.frame.height, 140)
        XCTAssertGreaterThan(scrollView.frame.height, 520)
    }

    func testAssistantComposerShowsCodexStyleToolsModelAndPermissionControls() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        let provider = makeModelProvider(
            id: UUID(uuidString: "75000000-0000-0000-0000-000000000001")!,
            name: "OpenAI",
            modelIDs: ["gpt-5.5", "qwen-plus"],
            defaultModelID: "gpt-5.5"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        store.update { settings in
            settings.agentConfirmationPolicy = .allowLowRiskWithoutPrompt
        }
        let panel = makeAssistantPanel(settingsStore: store)

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        panel.view.layoutSubtreeIfNeeded()

        let addButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.add") as? NSButton
        )
        let permissionButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.permission") as? NSButton
        )
        let modelButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.model") as? NSButton
        )
        let contextRing = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.contextUsage")
        )
        let sendButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.ask") as? NSButton
        )

        XCTAssertEqual(addButton.accessibilityLabel(), "添加上下文")
        XCTAssertTrue(permissionButton.title.contains("低风险自动"))
        XCTAssertTrue(modelButton.title.contains("gpt-5.5"))
        XCTAssertGreaterThan(permissionButton.frame.minX, addButton.frame.maxX)
        XCTAssertGreaterThan(modelButton.frame.minX, permissionButton.frame.maxX)
        XCTAssertEqual(modelButton.image, nil)
        XCTAssertGreaterThan(contextRing.frame.minX, modelButton.frame.maxX)
        XCTAssertGreaterThan(sendButton.frame.minX, contextRing.frame.maxX)
        XCTAssertLessThanOrEqual(contextRing.frame.width, 16)
    }

    func testAssistantComposerAddPickerExposesAttachmentAndModeActions() throws {
        let panel = makeAssistantPanel()

        panel.loadView()

        let titles = panel.composerAddPickerTitlesForTesting

        XCTAssertEqual(titles, [
            "添加照片和文件",
            "附加当前文件",
            "计划模式",
            "追求目标"
        ])
        let buttonHeights = panel.composerAddPickerButtonHeightsForTesting
        XCTAssertLessThanOrEqual(panel.composerAddPickerPreferredSizeForTesting.width, 172)
        XCTAssertLessThanOrEqual(panel.composerAddPickerPreferredSizeForTesting.height, 132)
        XCTAssertTrue(buttonHeights.allSatisfy { (26...30).contains($0) }, "button heights: \(buttonHeights)")
    }

    func testAssistantComposerAttachesCurrentRemoteTextFileAsRequestContext() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "已读取远端文件。", commandProposals: [])
        )
        let panel = makeAssistantPanel(
            provider: provider,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            currentRemoteFileAttachmentProvider: {
                AIAssistantAttachment(
                    filename: "app.conf",
                    mimeType: "text/plain",
                    byteCount: 28,
                    textPreview: "PORT=3000\nHOST=127.0.0.1"
                )
            }
        )

        panel.loadView()
        panel.addCurrentRemoteFileContextForTesting()

        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 1)
        XCTAssertEqual(panel.composerAttachmentCardTitlesForTesting, ["app.conf"])
        XCTAssertEqual(panel.statusTextForTesting, "已附加当前文件：app.conf")

        panel.setQuestionForTesting("这个配置文件有什么问题")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.requests.count == 1 })
        let attachment = try XCTUnwrap(provider.requests.first?.attachments.first)
        XCTAssertEqual(attachment.filename, "app.conf")
        XCTAssertEqual(attachment.mimeType, "text/plain")
        XCTAssertTrue(attachment.textPreview?.contains("PORT=3000") == true)
    }

    func testAssistantComposerReportsCurrentRemoteFileAttachmentRejection() throws {
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            currentRemoteFileAttachmentProvider: {
                throw AIAssistantRemoteFileAttachmentError.fileTooLarge
            }
        )

        panel.loadView()
        panel.addCurrentRemoteFileContextForTesting()

        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 0)
        XCTAssertEqual(panel.statusTextForTesting, "文件过大，无法作为 AI 上下文")
    }

    func testAssistantComposerDisablesCurrentRemoteFileActionWhenUnavailable() throws {
        let panel = makeAssistantPanel(
            currentRemoteFileAttachmentProvider: {
                AIAssistantAttachment(
                    filename: "disabled.conf",
                    mimeType: "text/plain",
                    byteCount: 8,
                    textPreview: "disabled"
                )
            },
            currentRemoteFileAttachmentAvailabilityProvider: { false }
        )

        panel.loadView()

        XCTAssertFalse(panel.composerAddPickerCurrentFileEnabledForTesting)
    }

    func testAssistantComposerPermissionPickerUsesPopoverStyleRows() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        store.update { settings in
            settings.agentConfirmationPolicy = .allowLowRiskWithoutPrompt
        }
        let panel = makeAssistantPanel(settingsStore: store)

        panel.loadView()

        XCTAssertEqual(panel.composerPermissionPickerTitlesForTesting, [
            "完全访问",
            "低风险自动",
            "只读自动",
            "每条确认"
        ])
        XCTAssertLessThanOrEqual(panel.composerPermissionPickerPreferredSizeForTesting.width, 168)
        XCTAssertLessThanOrEqual(panel.composerPermissionPickerPreferredSizeForTesting.height, 144)
        XCTAssertTrue(panel.composerPermissionPickerButtonHeightsForTesting.allSatisfy { (26...30).contains($0) })
    }

    func testAssistantComposerAddFilesUsesFinderSelectionAsRequestAttachment() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "已读取附件。", commandProposals: [])
        )
        let attachmentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioAI-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try "hello from local file".write(to: attachmentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: attachmentURL) }
        let panel = makeAssistantPanel(
            provider: provider,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            attachmentPicker: { [attachmentURL] }
        )

        panel.loadView()
        panel.addFilesContextForTesting()
        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 1)
        XCTAssertEqual(panel.composerAttachmentCardTitlesForTesting, [attachmentURL.lastPathComponent])
        XCTAssertTrue(panel.composerContextTextForTesting.contains("附件 1") == false)

        panel.setQuestionForTesting("总结这个文件")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.requests.count == 1 })
        XCTAssertEqual(provider.requests.first?.attachments.first?.filename, attachmentURL.lastPathComponent)
        XCTAssertEqual(provider.requests.first?.attachments.first?.mimeType, "text/plain")
        XCTAssertTrue(provider.requests.first?.attachments.first?.textPreview?.contains("hello from local file") == true)
    }

    func testAssistantComposerPasteAddsFileURLAttachment() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "已读取粘贴附件。", commandProposals: [])
        )
        let attachmentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioPaste-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try "pasted file content".write(to: attachmentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: attachmentURL) }
        let panel = makeAssistantPanel(
            provider: provider,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([attachmentURL as NSURL])

        panel.loadView()
        XCTAssertTrue(panel.addComposerPasteboardForTesting(pasteboard))
        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 1)
        XCTAssertEqual(panel.composerAttachmentCardTitlesForTesting, [attachmentURL.lastPathComponent])
        panel.setQuestionForTesting("看这个文件")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.requests.count == 1 })
        XCTAssertEqual(provider.requests.first?.attachments.first?.filename, attachmentURL.lastPathComponent)
        XCTAssertTrue(provider.requests.first?.attachments.first?.textPreview?.contains("pasted file content") == true)
    }

    func testAssistantComposerPasteAddsImageAttachment() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "已读取图片。", commandProposals: [])
        )
        let panel = makeAssistantPanel(
            provider: provider,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        pasteboard.writeObjects([image])

        panel.loadView()
        XCTAssertTrue(panel.addComposerPasteboardForTesting(pasteboard))
        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 1)
        XCTAssertTrue(panel.composerAttachmentCardTitlesForTesting.first?.hasPrefix("pasted-image-") == true)
        panel.setQuestionForTesting("看这张图")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.requests.count == 1 })
        let attachment = try XCTUnwrap(provider.requests.first?.attachments.first)
        XCTAssertTrue(attachment.filename.hasPrefix("pasted-image-"))
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertNotNil(attachment.base64Data)
    }

    func testAssistantComposerDragImageFileDoesNotDuplicateImageRepresentation() throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioDragImage-\(UUID().uuidString)")
            .appendingPathExtension("png")
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            return XCTFail("expected png data")
        }
        try data.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let panel = makeAssistantPanel(settingsStore: makeSettingsStore(autoRunProposedCommands: false))
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects([imageURL as NSURL, image])

        panel.loadView()
        XCTAssertTrue(panel.addComposerPasteboardForTesting(pasteboard))

        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 1)
        XCTAssertEqual(panel.composerAttachmentCardTitlesForTesting, [imageURL.lastPathComponent])
    }

    func testAssistantComposerAttachmentCardCanRemoveAndPreviewFile() throws {
        let attachmentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioPreview-\(UUID().uuidString)")
            .appendingPathExtension("md")
        try "# Preview\nhello".write(to: attachmentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: attachmentURL) }
        let panel = makeAssistantPanel(
            settingsStore: makeSettingsStore(autoRunProposedCommands: false),
            attachmentPicker: { [attachmentURL] }
        )

        panel.loadView()
        panel.addFilesContextForTesting()
        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 1)

        panel.previewComposerAttachmentForTesting(at: 0)
        XCTAssertEqual(panel.composerPreviewWindowTitleForTesting, attachmentURL.lastPathComponent)

        panel.removeComposerAttachmentForTesting(at: 0)
        XCTAssertEqual(panel.composerAttachmentCardCountForTesting, 0)
        XCTAssertTrue(panel.composerAttachmentStackHiddenForTesting)
    }

    func testAssistantComposerModesAreSentAsCodexStyleInstructions() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "已进入计划。", commandProposals: [])
        )
        let panel = makeAssistantPanel(
            provider: provider,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.togglePlanModeForTesting()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("优化部署流程")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.requests.count == 1 })
        XCTAssertTrue(provider.requests.first?.question.contains("Codex Plan 模式") == true)
        XCTAssertTrue(provider.requests.first?.question.contains("Codex 目标模式") == true)
    }

    func testAssistantPlanModeShowsPlanWithoutExecutingCommands() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(
                message: "计划：先看负载，再看磁盘。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "判断 CPU 压力。", risk: .readOnly),
                    AgentCommandProposal(command: "df -h", explanation: "判断磁盘空间。", risk: .readOnly)
                ]
            )
        )
        let execution = RecordingAgentCommandExecutor()
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: true)
        )

        panel.loadView()
        panel.togglePlanModeForTesting()
        panel.setQuestionForTesting("先规划怎么排查")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.planTimelineTextForTesting.contains("等待确认") })
        XCTAssertEqual(execution.requests.count, 0)
        XCTAssertTrue(panel.transcriptTextForTesting.contains("计划：先看负载，再看磁盘。"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("1. uptime"))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("确认执行"))
        XCTAssertTrue(panel.planConfirmEnabledForTesting)
        XCTAssertTrue(panel.planCancelEnabledForTesting)
    }

    func testAssistantPlanModeCancelIgnoresDelayedPlanResult() throws {
        let provider = DelayedAIAssistantProvider(
            response: AIAssistantResponse(
                message: "计划：先看负载，再看磁盘。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "判断 CPU 压力。", risk: .readOnly),
                    AgentCommandProposal(command: "df -h", explanation: "判断磁盘空间。", risk: .readOnly)
                ]
            ),
            delay: 0.08
        )
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: RecordingAgentCommandExecutor(),
            settingsStore: makeSettingsStore(autoRunProposedCommands: true)
        )

        panel.loadView()
        panel.togglePlanModeForTesting()
        panel.setQuestionForTesting("先规划怎么排查")
        panel.performAskForTesting()

        panel.performTaskCancelForTesting()

        XCTAssertEqual(panel.statusTextForTesting, "自主执行已取消。")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertFalse(panel.planTimelineTextForTesting.contains("等待确认"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("计划：先看负载，再看磁盘。"))
        XCTAssertFalse(panel.planConfirmEnabledForTesting)
    }

    func testAssistantPlanConfirmUsesActualCommandTaskControlsAfterPlanGeneration() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(
                message: "计划：持续查看日志。",
                commandProposals: [
                    AgentCommandProposal(
                        command: "tail -f /var/log/messages",
                        explanation: "观察实时日志。",
                        risk: .readOnly
                    )
                ]
            )
        )
        let execution = RecordingAgentCommandExecutor(events: [
            AgentTraceEvent(
                requestID: "confirmed-plan-task",
                state: .running,
                message: "命令已在终端执行，输出将实时显示",
                redactedCommand: "tail -f /var/log/messages",
                metadata: ["executionMode": "visibleTerminal"]
            )
        ])
        execution.pauseEvents["confirmed-plan-task"] = AgentTraceEvent(
            requestID: "confirmed-plan-task",
            state: .paused,
            message: "AI 后续自动动作已暂停；当前命令仍以目标终端输出为准。",
            redactedCommand: "tail -f /var/log/messages",
            metadata: ["control": "pause"]
        )
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: true)
        )

        panel.loadView()
        panel.togglePlanModeForTesting()
        panel.setQuestionForTesting("先规划，再看日志")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.planConfirmEnabledForTesting })

        panel.performPlanConfirmForTesting()
        XCTAssertTrue(waitUntil { panel.taskPauseEnabledForTesting })
        panel.performTaskPauseForTesting()

        XCTAssertEqual(execution.pausedRequestIDs, execution.requests.map(\.id))
        XCTAssertTrue(panel.transcriptTextForTesting.contains("自主执行已暂停"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("AI 后续自动动作已暂停"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("agent-step-"))
    }

    func testAssistantPlanConfirmStopsBeforeNextCommandWhenFirstStepNeedsManualCompletion() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(
                message: "计划：先跟踪日志，再看负载。",
                commandProposals: [
                    AgentCommandProposal(
                        command: "tail -f /var/log/messages",
                        explanation: "持续观察日志。",
                        risk: .readOnly
                    ),
                    AgentCommandProposal(
                        command: "uptime",
                        explanation: "查看负载。",
                        risk: .readOnly
                    )
                ]
            )
        )
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "tail -f /var/log/messages": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .running,
                    message: "命令已在终端执行，输出将实时显示",
                    redactedCommand: "tail -f /var/log/messages",
                    metadata: ["executionMode": "visibleTerminal"]
                ),
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .waitingForOutput,
                    message: "这条命令可能仍在运行，Stacio 不会根据静默输出自动判定完成；请手动停止、确认或接管。",
                    redactedCommand: "tail -f /var/log/messages",
                    metadata: [
                        "executionMode": "visibleTerminal",
                        "completionConfidence": "manualRequired"
                    ]
                )
            ],
            "uptime": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "本次命令已完成：load average: 0.01",
                    redactedCommand: "uptime",
                    metadata: ["terminalOutputSummary": "load average: 0.01"]
                )
            ]
        ])
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: true)
        )

        panel.loadView()
        panel.togglePlanModeForTesting()
        panel.setQuestionForTesting("先规划，再执行")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.planConfirmEnabledForTesting })

        panel.performPlanConfirmForTesting()

        XCTAssertTrue(waitUntil { execution.commands == ["tail -f /var/log/messages"] })
        XCTAssertTrue(panel.taskControlTextForTesting.contains("确认完成"))
        XCTAssertTrue(panel.taskControlTextForTesting.contains("长驻或交互命令"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("$ uptime"))
        XCTAssertTrue(panel.taskConfirmCompleteEnabledForTesting)
    }

    func testAssistantGoalModeRunsAutonomousLoopAndMergesTraceIntoConversation() throws {
        let provider = SequencedPanelAIAssistantProvider(responses: [
            AIAssistantResponse(
                message: "先看负载。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(message: "负载正常，完成。", commandProposals: [])
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "agent-step-1",
                    state: .running,
                    message: "AI 独立任务输出：load average: 0.05",
                    redactedCommand: "uptime",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "load average: 0.05"
                    ]
                ),
                AgentTraceEvent(
                    requestID: "agent-step-1",
                    state: .completed,
                    message: "AI 独立任务已完成：load average: 0.05",
                    redactedCommand: "uptime",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "load average: 0.05"
                    ]
                )
            ]
        ])
        let taskStore = RecordingAgentTaskStore()
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: execution,
            taskRecorder: taskStore
        )

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("检查这台机器是否正常")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.transcriptTextForTesting.contains("我开始自主推进这个目标。")
                && panel.rawTranscriptTextForTesting.contains("load average: 0.05")
                && panel.transcriptTextForTesting.contains("负载正常，完成。")
        })
        XCTAssertEqual(execution.requests.count, 1)
        XCTAssertTrue(provider.requests.last?.question.contains("load average: 0.05") == true)
        XCTAssertEqual(panel.commandCardCountForTesting, 0)
        XCTAssertEqual(taskStore.records.last?.session.state, .completed)
    }

    func testAssistantGoalModeStepLimitWaitsForUserContinueAndPreservesHistory() throws {
        let provider = SequencedPanelAIAssistantProvider(responses: [
            AIAssistantResponse(
                message: "先确认目录。",
                commandProposals: [
                    AgentCommandProposal(command: "pwd", explanation: "查看当前目录。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "根据目录继续列文件。",
                commandProposals: [
                    AgentCommandProposal(command: "ls", explanation: "查看目录内容。", risk: .readOnly)
                ]
            )
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "pwd": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：/srv/app",
                    redactedCommand: "pwd",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "/srv/app"
                    ]
                )
            ],
            "ls": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：app.log",
                    redactedCommand: "ls",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "app.log"
                    ]
                )
            ]
        ])
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: "term_1",
                    title: "dev@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            },
            settingsStore: makeSettingsStore(autoRunProposedCommands: true),
            agentTaskLoopLimits: AgentTaskLoopLimits(maxSteps: 1, maxDuration: 60)
        )

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("逐层找大文件")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.transcriptTextForTesting.contains("已达到自主执行步数上限")
        })
        XCTAssertEqual(execution.commands, ["pwd"])
        XCTAssertEqual(provider.requests.count, 1)

        let continueButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.taskControl.continue") as? NSButton
        )
        XCTAssertTrue(continueButton.isEnabled)

        continueButton.performClick(nil)

        XCTAssertTrue(waitUntil {
            execution.commands == ["pwd", "ls"]
        })
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertTrue(provider.requests[1].question.contains("/srv/app"))
        XCTAssertFalse(execution.commands.contains("pwd pwd"))
    }

    func testAssistantAutonomousTaskRetainsCapturedModelSelectionAcrossDefaultChangeAndContinue() throws {
        let store = makeSettingsStore(autoRunProposedCommands: true)
        let providerA = makeModelProvider(
            id: UUID(uuidString: "7A000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["a"],
            defaultModelID: "a"
        )
        let providerB = makeModelProvider(
            id: UUID(uuidString: "7A000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            modelIDs: ["b"],
            defaultModelID: "b"
        )
        let initialEnvelope = AIProviderSettingsEnvelope(
            aiProviders: [providerA, providerB],
            defaultAIProviderID: providerA.id
        )
        try store.saveAIProviderSettings(initialEnvelope)
        let selectionSession = AIModelSelectionSession()
        let provider = SelectionSnapshottingAIAssistantProvider(
            selectionSession: selectionSession,
            responses: [
                AIAssistantResponse(
                    message: "先确认目录。",
                    commandProposals: [
                        AgentCommandProposal(command: "pwd", explanation: "查看目录。", risk: .readOnly)
                    ]
                ),
                AIAssistantResponse(
                    message: "继续列出文件。",
                    commandProposals: [
                        AgentCommandProposal(command: "ls", explanation: "查看文件。", risk: .readOnly)
                    ]
                )
            ],
            onFirstRequest: {
                try? store.saveAIProviderSettings(
                    AIProviderSettingsEnvelope(
                        aiProviders: [providerA, providerB],
                        defaultAIProviderID: providerB.id
                    )
                )
            }
        )
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "pwd": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：/srv/app",
                    redactedCommand: "pwd",
                    metadata: ["terminalOutputSummary": "/srv/app"]
                )
            ],
            "ls": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：app.log",
                    redactedCommand: "ls",
                    metadata: ["terminalOutputSummary": "app.log"]
                )
            ]
        ])
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: "term_1",
                    title: "dev@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            },
            settingsStore: store,
            modelSelectionSession: selectionSession,
            agentTaskLoopLimits: AgentTaskLoopLimits(maxSteps: 1, maxDuration: 60)
        )

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("逐层检查目录")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            provider.selectionSnapshots.count == 1
                && panel.transcriptTextForTesting.contains("已达到自主执行步数上限")
        })
        let captured = AIModelSelection(providerID: providerA.id, modelID: "a")
        XCTAssertEqual(provider.selectionSnapshots, [captured])
        XCTAssertEqual(try store.loadAIProviderSettings().defaultAIProviderID, providerB.id)

        selectionSession.select(AIModelSelection(providerID: providerB.id, modelID: "b"))
        let continueButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.taskControl.continue") as? NSButton
        )
        continueButton.performClick(nil)

        XCTAssertTrue(waitUntil { provider.selectionSnapshots.count == 2 })
        XCTAssertEqual(provider.selectionSnapshots, [captured, captured])
    }

    func testAssistantAutonomousTaskRestoresPanelSelectionWhenContinueFails() throws {
        let store = makeSettingsStore(autoRunProposedCommands: true)
        let providerConfiguration = makeModelProvider(
            id: UUID(uuidString: "7B000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["a"],
            defaultModelID: "a"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerConfiguration],
                defaultAIProviderID: providerConfiguration.id
            )
        )
        let selectionSession = AIModelSelectionSession()
        let provider = SelectionSnapshottingResultAIAssistantProvider(
            selectionSession: selectionSession,
            results: [
                .success(
                    AIAssistantResponse(
                        message: "先确认目录。",
                        commandProposals: [
                            AgentCommandProposal(command: "pwd", explanation: "查看目录。", risk: .readOnly)
                        ]
                    )
                ),
                .failure(AIAssistantProviderError.invalidResponse)
            ]
        )
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "pwd": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：/srv/app",
                    redactedCommand: "pwd",
                    metadata: ["terminalOutputSummary": "/srv/app"]
                )
            ]
        ])
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: "term_1",
                    title: "dev@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            },
            settingsStore: store,
            modelSelectionSession: selectionSession,
            agentTaskLoopLimits: AgentTaskLoopLimits(maxSteps: 1, maxDuration: 60)
        )

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("逐层检查目录")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.transcriptTextForTesting.contains("已达到自主执行步数上限")
        })
        let captured = AIModelSelection(providerID: providerConfiguration.id, modelID: "a")
        XCTAssertEqual(provider.selectionSnapshots, [captured])

        let continueButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.taskControl.continue") as? NSButton
        )
        continueButton.performClick(nil)

        XCTAssertTrue(waitUntil {
            panel.transcriptTextForTesting.contains("继续执行失败")
        })
        XCTAssertEqual(provider.selectionSnapshots, [captured, captured])
        XCTAssertNil(selectionSession.snapshot())
        let modelButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.model") as? NSButton
        )
        XCTAssertTrue(modelButton.isEnabled)
    }

    func testAssistantNormalQuestionAfterStepLimitRestoresPanelModelSelection() throws {
        let store = makeSettingsStore(autoRunProposedCommands: true)
        let providerConfiguration = makeModelProvider(
            id: UUID(uuidString: "7C000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["a"],
            defaultModelID: "a"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerConfiguration],
                defaultAIProviderID: providerConfiguration.id
            )
        )
        let selectionSession = AIModelSelectionSession()
        let provider = SelectionSnapshottingAIAssistantProvider(
            selectionSession: selectionSession,
            responses: [
                AIAssistantResponse(
                    message: "先确认目录。",
                    commandProposals: [
                        AgentCommandProposal(command: "pwd", explanation: "查看目录。", risk: .readOnly)
                    ]
                ),
                AIAssistantResponse(message: "普通问题已回答。", commandProposals: [])
            ],
            onFirstRequest: {}
        )
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "pwd": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .completed,
                    message: "AI 独立任务已完成：/srv/app",
                    redactedCommand: "pwd",
                    metadata: ["terminalOutputSummary": "/srv/app"]
                )
            ]
        ])
        let panel = AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(provider: provider, executionCoordinator: execution),
            contextProvider: { _ in
                AITerminalContext(
                    runtimeID: "term_1",
                    title: "dev@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: ""
                )
            },
            settingsStore: store,
            modelSelectionSession: selectionSession,
            agentTaskLoopLimits: AgentTaskLoopLimits(maxSteps: 1, maxDuration: 60)
        )

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("逐层检查目录")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            panel.transcriptTextForTesting.contains("已达到自主执行步数上限")
        })
        let captured = AIModelSelection(providerID: providerConfiguration.id, modelID: "a")
        XCTAssertEqual(selectionSession.snapshot(), captured)
        let modelButton = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.composer.model") as? NSButton
        )
        XCTAssertFalse(modelButton.isEnabled)

        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("这是一个普通问题")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil {
            provider.selectionSnapshots.count == 2
                && panel.assistantTranscriptTextForTesting.contains("普通问题已回答。")
        })
        XCTAssertEqual(provider.selectionSnapshots, [captured, nil])
        XCTAssertNil(selectionSession.snapshot())
        XCTAssertTrue(modelButton.isEnabled)
    }

    func testAssistantGoalModePauseControlStopsAutonomousLoop() throws {
        let provider = SequencedPanelAIAssistantProvider(responses: [
            AIAssistantResponse(
                message: "持续看日志。",
                commandProposals: [
                    AgentCommandProposal(command: "tail -f /var/log/messages", explanation: "观察日志。", risk: .readOnly)
                ]
            ),
            AIAssistantResponse(
                message: "不应继续。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "不应执行。", risk: .readOnly)
                ]
            )
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "tail -f /var/log/messages": [
                AgentTraceEvent(
                    requestID: "agent-step-1",
                    state: .running,
                    message: "命令已在终端执行，输出将实时显示",
                    redactedCommand: "tail -f /var/log/messages",
                    metadata: ["executionMode": "visibleTerminal"]
                )
            ]
        ])
        execution.pauseEvents["agent-step-1"] = AgentTraceEvent(
            requestID: "agent-step-1",
            state: .paused,
            message: "AI 后续自动动作已暂停；当前命令仍以目标终端输出为准。",
            redactedCommand: "tail -f /var/log/messages",
            metadata: ["control": "pause"]
        )
        let panel = makeAssistantPanel(provider: provider, executionCoordinator: execution)

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("观察日志")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.taskPauseEnabledForTesting })

        panel.performTaskPauseForTesting()

        XCTAssertTrue(waitUntil { panel.transcriptTextForTesting.contains("自主执行已暂停") })
        XCTAssertEqual(execution.pausedRequestIDs, execution.requests.map(\.id))
        XCTAssertEqual(execution.requests.count, 1)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertFalse(panel.taskPauseEnabledForTesting)
    }

    func testAssistantGoalModeCancelDuringNextDecisionIgnoresDelayedResponse() throws {
        let provider = DelayedSequencedPanelAIAssistantProvider(responses: [
            (
                AIAssistantResponse(
                    message: "先看负载。",
                    commandProposals: [
                        AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                    ]
                ),
                0
            ),
            (
                AIAssistantResponse(
                    message: "不应继续。",
                    commandProposals: [
                        AgentCommandProposal(command: "df -h", explanation: "不应执行。", risk: .readOnly)
                    ]
                ),
                0.12
            )
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "agent-step-1",
                    state: .completed,
                    message: "AI 独立任务已完成：load average: 0.05",
                    redactedCommand: "uptime",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "load average: 0.05"
                    ]
                )
            ]
        ])
        let panel = makeAssistantPanel(provider: provider, executionCoordinator: execution)

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("检查这台机器是否正常")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { provider.requests.count == 2 })

        panel.performTaskCancelForTesting()
        XCTAssertEqual(execution.cancelledRequestIDs, execution.requests.map(\.id))
        XCTAssertTrue(panel.statusTextForTesting.contains("自主执行已取消"))

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(panel.statusTextForTesting.contains("自主执行已取消"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("不应继续。"))
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(execution.commands, ["uptime"])
    }

    func testAssistantGoalModeCancelDuringNextDecisionIgnoresDelayedProgress() throws {
        let provider = DelayedSequencedPanelAIAssistantProvider(responses: [
            (
                AIAssistantResponse(
                    message: "先看负载。",
                    commandProposals: [
                        AgentCommandProposal(command: "uptime", explanation: "查看负载。", risk: .readOnly)
                    ]
                ),
                0
            ),
            (
                AIAssistantResponse(
                    message: "取消后不应再污染面板。",
                    commandProposals: []
                ),
                0.12
            )
        ])
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "uptime": [
                AgentTraceEvent(
                    requestID: "agent-step-1",
                    state: .completed,
                    message: "AI 独立任务已完成：load average: 0.05",
                    redactedCommand: "uptime",
                    metadata: [
                        "executionMode": "backgroundTask",
                        "terminalOutputSummary": "load average: 0.05"
                    ]
                )
            ]
        ])
        let panel = makeAssistantPanel(provider: provider, executionCoordinator: execution)

        panel.loadView()
        panel.toggleGoalModeForTesting()
        panel.setQuestionForTesting("检查这台机器是否正常")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { provider.requests.count == 2 })

        panel.performTaskCancelForTesting()
        let transcriptAtCancel = panel.transcriptTextForTesting
        let returnedProgressCountAtCancel = transcriptAtCancel.components(separatedBy: "AI 已返回结果").count - 1

        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(panel.statusTextForTesting.contains("自主执行已取消"))
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(execution.commands, ["uptime"])
        XCTAssertEqual(
            panel.transcriptTextForTesting.components(separatedBy: "AI 已返回结果").count - 1,
            returnedProgressCountAtCancel
        )
    }

    func testAssistantComposerSelectionDistinguishesSameNamedModelsWithoutChangingGlobalDefault() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        let providerA = makeModelProvider(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["shared", "a-only"],
            defaultModelID: "shared"
        )
        let providerB = makeModelProvider(
            id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            modelIDs: ["shared", "b-only"],
            defaultModelID: "shared"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: providerA.id
            )
        )
        let selectionSession = AIModelSelectionSession()
        let panel = makeAssistantPanel(
            settingsStore: store,
            modelSelectionSession: selectionSession
        )

        panel.loadView()
        let selected = AIModelSelection(providerID: providerB.id, modelID: "shared")
        panel.selectComposerModelForTesting(selected)

        XCTAssertEqual(selectionSession.snapshot(), selected)
        XCTAssertEqual(try store.loadAIProviderSettings().defaultAIProviderID, providerA.id)
        XCTAssertEqual(panel.composerModelPickerGroupTitlesForTesting, ["Provider A", "Provider B"])
        XCTAssertEqual(panel.composerModelPickerSelectionsForTesting, [
            AIModelSelection(providerID: providerA.id, modelID: "shared"),
            AIModelSelection(providerID: providerA.id, modelID: "a-only"),
            AIModelSelection(providerID: providerB.id, modelID: "shared"),
            AIModelSelection(providerID: providerB.id, modelID: "b-only")
        ])
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("Provider B"))
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("shared"))
    }

    func testAssistantComposerValidTemporarySelectionSurvivesDefaultChange() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        let providerA = makeModelProvider(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["a"],
            defaultModelID: "a"
        )
        let providerB = makeModelProvider(
            id: UUID(uuidString: "72000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            modelIDs: ["b"],
            defaultModelID: "b"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: providerA.id
            )
        )
        let selected = AIModelSelection(providerID: providerB.id, modelID: "b")
        let selectionSession = AIModelSelectionSession(selection: selected)
        let panel = makeAssistantPanel(
            settingsStore: store,
            modelSelectionSession: selectionSession
        )
        panel.loadView()

        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: BuiltInAIProvider.stacioRulesID
            )
        )

        XCTAssertEqual(selectionSession.snapshot(), selected)
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("Provider B"))
    }

    func testAssistantComposerInvalidTemporarySelectionClearsToGlobalDefault() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        let providerA = makeModelProvider(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["a"],
            defaultModelID: "a"
        )
        let providerB = makeModelProvider(
            id: UUID(uuidString: "73000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            modelIDs: ["b"],
            defaultModelID: "b"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: providerA.id
            )
        )
        let selectionSession = AIModelSelectionSession(
            selection: AIModelSelection(providerID: providerB.id, modelID: "b")
        )
        let panel = makeAssistantPanel(
            settingsStore: store,
            modelSelectionSession: selectionSession
        )
        panel.loadView()

        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA],
                defaultAIProviderID: providerA.id
            )
        )

        XCTAssertNil(selectionSession.snapshot())
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("Provider A"))
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("a"))
    }

    func testAssistantComposerModelSelectionSessionsAreIndependent() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        let providerA = makeModelProvider(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["a"],
            defaultModelID: "a"
        )
        let providerB = makeModelProvider(
            id: UUID(uuidString: "74000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            modelIDs: ["b"],
            defaultModelID: "b"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: providerA.id
            )
        )
        let firstSession = AIModelSelectionSession()
        let secondSession = AIModelSelectionSession()
        let firstPanel = makeAssistantPanel(settingsStore: store, modelSelectionSession: firstSession)
        let secondPanel = makeAssistantPanel(settingsStore: store, modelSelectionSession: secondSession)
        firstPanel.loadView()
        secondPanel.loadView()

        firstPanel.selectComposerModelForTesting(
            AIModelSelection(providerID: providerB.id, modelID: "b")
        )

        XCTAssertEqual(
            firstSession.snapshot(),
            AIModelSelection(providerID: providerB.id, modelID: "b")
        )
        XCTAssertNil(secondSession.snapshot())
        XCTAssertTrue(firstPanel.composerModelTitleForTesting.contains("Provider B"))
        XCTAssertTrue(secondPanel.composerModelTitleForTesting.contains("Provider A"))
    }

    func testAssistantComposerOmitsRulesAndClearsLegacyRulesSelection() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        let providerA = makeModelProvider(
            id: UUID(uuidString: "7D000000-0000-0000-0000-000000000001")!,
            name: "Provider A",
            modelIDs: ["a"],
            defaultModelID: "a"
        )
        let providerB = makeModelProvider(
            id: UUID(uuidString: "7D000000-0000-0000-0000-000000000002")!,
            name: "Provider B",
            modelIDs: ["b"],
            defaultModelID: "b"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [providerA, providerB],
                defaultAIProviderID: providerA.id
            )
        )
        let rules = AIModelSelection(providerID: BuiltInAIProvider.stacioRulesID, modelID: "")
        let selectionSession = AIModelSelectionSession(selection: rules)
        let panel = makeAssistantPanel(
            settingsStore: store,
            modelSelectionSession: selectionSession
        )

        panel.loadView()
        XCTAssertNil(selectionSession.snapshot())
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("Provider A"))

        let external = AIModelSelection(providerID: providerB.id, modelID: "b")
        panel.selectComposerModelForTesting(external)

        XCTAssertEqual(selectionSession.snapshot(), external)
        XCTAssertTrue(panel.composerModelPickerModelTitlesForTesting.contains("跟随全局默认"))
        XCTAssertFalse(panel.composerModelPickerModelTitlesForTesting.contains(L10n.Settings.portDeskRules))
        XCTAssertFalse(panel.composerModelMenuModelTitlesForTesting.contains(L10n.Settings.portDeskRules))

        panel.selectComposerModelForTesting(rules)

        XCTAssertNil(selectionSession.snapshot())
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("Provider A"))
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("a"))
    }

    func testAssistantComposerModelMenuExposesReasoningAndAddedModels() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        let provider = makeModelProvider(
            id: UUID(uuidString: "76000000-0000-0000-0000-000000000001")!,
            name: "OpenAI",
            modelIDs: ["GPT-5.5", "GPT-5.4", "GPT-5.4-Mini", "GPT-5.3-Codex"],
            defaultModelID: "GPT-5.5"
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let panel = makeAssistantPanel(settingsStore: store)

        panel.loadView()

        XCTAssertEqual(panel.composerModelMenuReasoningTitlesForTesting, ["低", "中", "高", "超高"])
        XCTAssertTrue(panel.composerModelMenuModelTitlesForTesting.contains("GPT-5.5"))
        XCTAssertTrue(panel.composerModelMenuModelTitlesForTesting.contains("GPT-5.4-Mini"))
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("GPT-5.5"))
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("高"))
    }

    func testAssistantComposerModelPickerShowsAddedModelsReasoningAndContextUsage() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        var provider = makeModelProvider(
            id: UUID(uuidString: "77000000-0000-0000-0000-000000000001")!,
            name: "OpenAI",
            modelIDs: ["GPT-5.5", "GPT-5.4", "GPT-5.4-Mini", "GPT-5.3-Codex"],
            defaultModelID: "GPT-5.5"
        )
        provider.models[0].capabilities = AIModelCapabilityConfiguration(
            contextCharacterLimit: 100,
            contextCharacterLimitSource: .manual
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let panel = makeAssistantPanel(
            settingsStore: store,
            recentTranscript: String(repeating: "x", count: 40)
        )

        panel.loadView()

        XCTAssertEqual(panel.composerModelPickerReasoningTitlesForTesting, ["低", "中", "高", "超高"])
        XCTAssertTrue(panel.composerModelPickerModelTitlesForTesting.contains("GPT-5.5"))
        XCTAssertTrue(panel.composerModelPickerModelTitlesForTesting.contains("GPT-5.4-Mini"))
        XCTAssertEqual(panel.composerModelPickerContextTextForTesting, "40%")
        XCTAssertLessThanOrEqual(panel.composerModelPickerPreferredSizeForTesting.height, 350)
        XCTAssertGreaterThanOrEqual(panel.composerModelPickerPreferredSizeForTesting.height, 320)
    }

    func testAssistantComposerModelPickerCompactsForSingleModel() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        var provider = makeModelProvider(
            id: UUID(uuidString: "78000000-0000-0000-0000-000000000001")!,
            name: "Compatible",
            modelIDs: ["gpt-5.5"],
            defaultModelID: "gpt-5.5"
        )
        provider.models[0].capabilities = AIModelCapabilityConfiguration(
            contextCharacterLimit: 100,
            contextCharacterLimitSource: .manual
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let panel = makeAssistantPanel(
            settingsStore: store,
            recentTranscript: String(repeating: "x", count: 7)
        )

        panel.loadView()

        XCTAssertEqual(
            panel.composerModelPickerModelTitlesForTesting,
            ["跟随全局默认", "gpt-5.5"]
        )
        XCTAssertEqual(panel.composerModelPickerContextTextForTesting, "7%")
        XCTAssertLessThanOrEqual(panel.composerModelPickerPreferredSizeForTesting.height, 340)
    }

    func testAssistantComposerReasoningMenuUpdatesSelectedModel() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        var provider = makeModelProvider(
            id: UUID(uuidString: "79000000-0000-0000-0000-000000000001")!,
            name: "OpenAI",
            modelIDs: ["GPT-5.5"],
            defaultModelID: "GPT-5.5"
        )
        provider.models[0].capabilities.reasoningEffort = .medium
        provider.models[0].capabilities.reasoningEffortSource = .manual
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let panel = makeAssistantPanel(settingsStore: store)

        panel.loadView()
        panel.selectComposerReasoningForTesting(.high)

        XCTAssertEqual(
            try store.loadAIProviderSettings().aiProviders[0].models[0].capabilities.reasoningEffort,
            .high
        )
        XCTAssertEqual(store.snapshot().aiReasoningEffort, .medium)
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("超高"))
    }

    func testAssistantComposerUsesSelectedModelCapabilitiesForReasoningAndContextBudget() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        var provider = makeModelProvider(
            id: UUID(uuidString: "7A000000-0000-0000-0000-000000000001")!,
            name: "Capabilities",
            modelIDs: ["capable-model"],
            defaultModelID: "capable-model"
        )
        provider.models[0].capabilities = AIModelCapabilityConfiguration(
            contextCharacterLimit: 100,
            contextCharacterLimitSource: .manual,
            supportedReasoningEfforts: [.minimal, .high],
            supportedReasoningEffortsSource: .catalog,
            reasoningEffort: .high,
            reasoningEffortSource: .catalog
        )
        try store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(aiProviders: [provider], defaultAIProviderID: provider.id)
        )
        let selection = AIModelSelection(providerID: provider.id, modelID: "capable-model")
        let panel = makeAssistantPanel(
            settingsStore: store,
            recentTranscript: String(repeating: "x", count: 40),
            modelSelectionSession: AIModelSelectionSession(selection: selection)
        )

        panel.loadView()

        XCTAssertEqual(panel.composerModelPickerReasoningTitlesForTesting, ["低", "超高"])
        XCTAssertEqual(panel.contextUsageFractionForTesting, 0.4, accuracy: 0.01)
        panel.selectComposerReasoningForTesting(.minimal)

        let savedModel = try XCTUnwrap(
            store.loadAIProviderSettings().aiProviders.first?.models.first
        )
        XCTAssertEqual(savedModel.capabilities.reasoningEffort, .minimal)
        XCTAssertEqual(savedModel.capabilities.reasoningEffortSource, .manual)
        XCTAssertEqual(store.snapshot().aiReasoningEffort, .medium)
        XCTAssertTrue(panel.composerModelTitleForTesting.contains("低"))
    }

    func testAssistantComposerShowsContextUsageRingFromCurrentContextBudget() throws {
        let store = makeSettingsStore(
            autoRunProposedCommands: false,
            modelContextCharacterLimit: 100
        )
        let panel = makeAssistantPanel(
            settingsStore: store,
            recentTranscript: String(repeating: "x", count: 40)
        )

        panel.loadView()

        XCTAssertEqual(panel.contextUsageFractionForTesting, 0.4, accuracy: 0.01)
        XCTAssertTrue(panel.contextUsageTextForTesting.contains("40%"))
    }

    func testAssistantComposerContextUsageReflectsCompressedTranscriptBudget() throws {
        let store = makeSettingsStore(
            autoRunProposedCommands: false,
            modelContextCharacterLimit: 100
        )
        store.update { settings in
            settings.aiIncludeRecentTerminalTranscript = true
        }
        let panel = makeAssistantPanel(
            settingsStore: store,
            recentTranscript: String(repeating: "terminal output\n", count: 30)
        )

        panel.loadView()

        XCTAssertLessThan(panel.contextUsageFractionForTesting, 0.8)
        XCTAssertFalse(panel.contextUsageTextForTesting.contains("100%"))
        XCTAssertTrue(panel.contextUsageTextForTesting.contains("已自动压缩"))
    }

    func testAssistantComposerPermissionMenuUpdatesConfirmationPolicy() throws {
        let store = makeSettingsStore(autoRunProposedCommands: false)
        store.update { settings in
            settings.agentConfirmationPolicy = .allowLowRiskWithoutPrompt
        }
        let panel = makeAssistantPanel(settingsStore: store)

        panel.loadView()
        panel.selectComposerPermissionForTesting(.requireEveryCommand)

        XCTAssertEqual(store.snapshot().agentConfirmationPolicy, .requireEveryCommand)
        XCTAssertTrue(panel.composerPermissionTitleForTesting.contains("每条确认"))
    }

    func testAssistantPanelConversationUsesScrollableTranscriptRegion() throws {
        let longMessage = String(repeating: "VeryLongAIResponseSegment ", count: 120)
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: longMessage, proposedCommand: nil)
            )
        )

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 300, height: 420)
        panel.setQuestionForTesting("长回复")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains("VeryLongAIResponseSegment") })
        panel.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let scrollView = try XCTUnwrap(
            panel.view.firstSubview(withIdentifier: "Stacio.AI.transcriptScroll") as? NSScrollView
        )
        let documentView = try XCTUnwrap(scrollView.documentView)
        let visibleHeight = scrollView.contentView.bounds.height
        let documentHeight = documentView.frame.height
        XCTAssertGreaterThan(scrollView.frame.height, 120)
        XCTAssertGreaterThan(documentHeight, visibleHeight)
        XCTAssertGreaterThanOrEqual(scrollView.contentView.bounds.maxY, documentHeight - 1)
        XCTAssertLessThanOrEqual(panel.view.fittingSize.height, 460)
    }

    func testAssistantTranscriptKeepsUnusedHeightBelowConversationContent() throws {
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(message: "CPU 负载正常。", proposedCommand: nil)
            )
        )

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 520, height: 900)
        panel.setQuestionForTesting("检查 CPU")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.assistantTranscriptTextForTesting.contains("CPU 负载正常") })
        panel.view.layoutSubtreeIfNeeded()

        let transcript = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript"))
        let spacer = try XCTUnwrap(panel.view.firstSubview(withIdentifier: "Stacio.AI.transcript.bottomSpacer"))
        XCTAssertGreaterThan(spacer.frame.height, 100)
        XCTAssertGreaterThanOrEqual(spacer.frame.minY, transcript.frame.maxY - 1)
    }

    func testAssistantMarkdownRendererStylesCodeBlocksAsMonospacedText() throws {
        let rendered = AIAssistantMarkdownRenderer.attributedString(
            from: """
            ### 检查命令
            请运行：

            ```bash
            journalctl -u nginx --no-pager
            ```
            """
        )

        XCTAssertTrue(rendered.string.contains("检查命令"))
        XCTAssertTrue(rendered.string.contains("journalctl -u nginx --no-pager"))
        var hasMonospacedCode = false
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard rendered.string.contains("journalctl"),
                  let font = value as? NSFont
            else {
                return
            }
            let substring = (rendered.string as NSString).substring(with: range)
            if substring.contains("journalctl"),
               font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                hasMonospacedCode = true
            }
        }
        XCTAssertTrue(hasMonospacedCode)
    }

    func testAssistantSendButtonBecomesStopDuringStreamingThenReturnsToSend() throws {
        let provider = HangingStreamingAIAssistantProvider()
        let panel = makeAssistantPanel(
            provider: provider,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.stop"))
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, L10n.AI.ask)
        panel.setQuestionForTesting("持续生成一段排查建议")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.generalStopEnabledForTesting && provider.started })
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, "停止当前 AI 请求")
        XCTAssertTrue(panel.assistantTranscriptTextForTesting.contains("正在生成"))

        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { provider.cancelled })
        XCTAssertTrue(panel.systemTranscriptTextForTesting.contains("已停止"))
        XCTAssertFalse(panel.assistantTranscriptTextForTesting.contains("已停止"))
        XCTAssertFalse(panel.generalStopEnabledForTesting)
        XCTAssertEqual(panel.primaryActionAccessibilityLabelForTesting, L10n.AI.ask)
    }

    func testAssistantShowsRunningTerminalTraceInTranscript() throws {
        let panel = makeAssistantPanel()

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 320, height: 460)
        NotificationCenter.default.post(
            name: Notification.Name("Stacio.Terminal.agentTraceDidAppend"),
            object: nil,
            userInfo: [
                "runtimeID": "term_1",
                "title": "dev@example.com",
                "event": AgentTraceEvent(
                    requestID: "req-trace",
                    state: .running,
                    message: "Stacio AI 正在执行 uptime",
                    redactedCommand: "uptime",
                    metadata: ["actorKind": AgentActorKind.builtInAI.rawValue]
                )
            ]
        )

        XCTAssertTrue(waitUntil {
            panel.statusTextForTesting.contains("Stacio AI 正在执行 uptime")
                && panel.transcriptTextForTesting.contains("终端 · dev@example.com")
                && panel.transcriptTextForTesting.contains("$ uptime")
                && panel.transcriptTextForTesting.contains("uptime")
        })
        XCTAssertTrue(panel.taskControlTextForTesting.contains("命令已交给目标终端"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("req-trace"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("running"))
        XCTAssertNil(panel.view.firstSubview(withIdentifier: "Stacio.AI.taskWorkspace"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("运行中 ·"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("执行："))
    }

    func testAssistantIgnoresExternalCLITraceFromCurrentTerminal() throws {
        let panel = makeAssistantPanel()

        panel.loadView()
        TerminalAgentTraceNotification.post(
            runtimeID: "term_1",
            title: "dev@example.com",
            event: AgentTraceEvent(
                requestID: "req-local-agent",
                state: .completed,
                message: "本次命令已完成：external output",
                redactedCommand: "free -h",
                metadata: [
                    "actorKind": AgentActorKind.externalCLI.rawValue,
                    "terminalOutputSummary": "external output"
                ]
            )
        )

        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("free -h"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("external output"))
        XCTAssertEqual(panel.statusTextForTesting, "")
    }

    func testTerminalTaskControlNotificationUsesSameCoordinatorAndHidesSidebarControlBar() throws {
        let execution = RecordingAgentCommandExecutor()
        execution.cancelEvents["req-terminal-control"] = AgentTraceEvent(
            requestID: "req-terminal-control",
            state: .cancelled,
            message: "已向可见终端发送中断；输出仍以目标终端为准。",
            redactedCommand: "tail -f /var/log/messages",
            metadata: ["executionMode": "visibleTerminal", "control": "cancel"]
        )
        let panel = makeAssistantPanel(executionCoordinator: execution)

        panel.loadView()
        NotificationCenter.default.post(
            name: TerminalAgentTraceNotification.didAppend,
            object: nil,
            userInfo: [
                TerminalAgentTraceNotification.runtimeIDKey: "term_1",
                TerminalAgentTraceNotification.titleKey: "dev@example.com",
                TerminalAgentTraceNotification.eventKey: AgentTraceEvent(
                    requestID: "req-terminal-control",
                    state: .running,
                    message: "命令已在终端执行",
                    redactedCommand: "tail -f /var/log/messages",
                    metadata: [
                        "executionMode": "visibleTerminal",
                        "actorKind": AgentActorKind.builtInAI.rawValue
                    ]
                )
            ]
        )
        NotificationCenter.default.post(
            name: TerminalAgentTaskControlNotification.didRequest,
            object: nil,
            userInfo: [
                TerminalAgentTaskControlNotification.runtimeIDKey: "term_1",
                TerminalAgentTaskControlNotification.requestIDKey: "req-terminal-control",
                TerminalAgentTaskControlNotification.actionKey: TerminalAgentTaskControlAction.cancel.rawValue
            ]
        )

        XCTAssertEqual(execution.cancelledRequestIDs, ["req-terminal-control"])
        XCTAssertTrue(panel.statusTextForTesting.contains("已向可见终端发送中断"))
        let sidebarControl = panel.view.firstSubview(withIdentifier: "Stacio.AI.taskControl")
        XCTAssertTrue(sidebarControl?.isHidden == true)
    }

    func testExternalCLITerminalControlExecutesWithoutUpdatingAssistantTranscript() throws {
        let execution = RecordingAgentCommandExecutor()
        execution.cancelEvents["req-external-control"] = AgentTraceEvent(
            requestID: "req-external-control",
            state: .cancelled,
            message: "external task cancelled",
            redactedCommand: "tail -f /var/log/messages",
            metadata: ["actorKind": AgentActorKind.externalCLI.rawValue]
        )
        let panel = makeAssistantPanel(executionCoordinator: execution)

        panel.loadView()
        TerminalAgentTraceNotification.post(
            runtimeID: "term_1",
            title: "dev@example.com",
            event: AgentTraceEvent(
                requestID: "req-external-control",
                state: .running,
                message: "local Agent running",
                redactedCommand: "tail -f /var/log/messages",
                metadata: ["actorKind": AgentActorKind.externalCLI.rawValue]
            )
        )
        NotificationCenter.default.post(
            name: TerminalAgentTaskControlNotification.didRequest,
            object: nil,
            userInfo: [
                TerminalAgentTaskControlNotification.runtimeIDKey: "term_1",
                TerminalAgentTaskControlNotification.requestIDKey: "req-external-control",
                TerminalAgentTaskControlNotification.actionKey: TerminalAgentTaskControlAction.cancel.rawValue
            ]
        )

        XCTAssertEqual(execution.cancelledRequestIDs, ["req-external-control"])
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("tail -f /var/log/messages"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("external task cancelled"))
        XCTAssertEqual(panel.statusTextForTesting, "")
    }

    func testNonSelectedTerminalControlExecutesWithoutUpdatingAssistantTranscript() throws {
        let execution = RecordingAgentCommandExecutor()
        execution.cancelEvents["req-other-terminal-control"] = AgentTraceEvent(
            requestID: "req-other-terminal-control",
            state: .cancelled,
            message: "other terminal task cancelled",
            redactedCommand: "tail -f /var/log/messages",
            metadata: ["actorKind": AgentActorKind.externalCLI.rawValue]
        )
        let panel = makeAssistantPanel(executionCoordinator: execution)

        panel.loadView()
        NotificationCenter.default.post(
            name: TerminalAgentTaskControlNotification.didRequest,
            object: nil,
            userInfo: [
                TerminalAgentTaskControlNotification.runtimeIDKey: "term_other",
                TerminalAgentTaskControlNotification.requestIDKey: "req-other-terminal-control",
                TerminalAgentTaskControlNotification.actionKey: TerminalAgentTaskControlAction.cancel.rawValue
            ]
        )

        XCTAssertEqual(execution.cancelledRequestIDs, ["req-other-terminal-control"])
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("tail -f /var/log/messages"))
        XCTAssertFalse(panel.rawTranscriptTextForTesting.contains("other terminal task cancelled"))
        XCTAssertEqual(panel.statusTextForTesting, "")
    }

    func testTaskCancelFallbackAppearsAsSystemNoticeNotAssistantReply() throws {
        let execution = RecordingAgentCommandExecutor(eventsByCommand: [
            "tail -f /var/log/system.log": [
                AgentTraceEvent(
                    requestID: "ignored",
                    state: .running,
                    message: "命令已交给目标终端",
                    redactedCommand: "tail -f /var/log/system.log",
                    metadata: ["executionMode": "visibleTerminal"]
                )
            ]
        ])
        let panel = makeAssistantPanel(
            provider: RecordingAIAssistantProvider(
                response: AIAssistantResponse(
                    message: "建议观察系统日志。",
                    commandProposals: [
                        AgentCommandProposal(
                            command: "tail -f /var/log/system.log",
                            explanation: "观察系统日志。",
                            risk: .readOnly
                        )
                    ]
                )
            ),
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.setQuestionForTesting("看日志")
        panel.performAskForTesting()
        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })
        panel.runCommandCardForTesting(at: 0)
        XCTAssertTrue(waitUntil { panel.taskCancelEnabledForTesting })

        panel.performTaskCancelForTesting()

        XCTAssertTrue(panel.systemTranscriptTextForTesting.contains("未找到活动控制句柄"))
        XCTAssertFalse(panel.assistantTranscriptTextForTesting.contains("未找到活动控制句柄"))
    }

    func testAssistantUpdatesStatusFromTerminalTraceCompletionNotification() throws {
        let panel = makeAssistantPanel()

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 320, height: 460)
        TerminalAgentTraceNotification.post(
            runtimeID: "term_1",
            title: "dev@example.com",
            event: AgentTraceEvent(
                requestID: "req-background",
                state: .completed,
                message: "AI 独立任务已完成：load average: 0.01",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "taskRuntimeID": "agent_bg_1"
                ]
            )
        )

        XCTAssertTrue(waitUntil {
            panel.rawTranscriptTextForTesting.contains("终端 · dev@example.com")
                && panel.rawTranscriptTextForTesting.contains("$ uptime")
                && panel.rawTranscriptTextForTesting.contains("load average: 0.01")
                && panel.statusTextForTesting.contains("AI 独立任务已完成")
        })
        XCTAssertGreaterThan(panel.collapsedProcessEntryCountForTesting, 0)
        XCTAssertFalse(panel.transcriptTextForTesting.contains("AI 独立任务已完成：load average: 0.01"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("完成：load average: 0.01"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("执行："))
        XCTAssertTrue(panel.statusTextForTesting.contains("load average: 0.01"))
        XCTAssertEqual(panel.taskControlTextForTesting, "")
    }

    func testAssistantShowsExecutionPolicyMetadataInTranscript() throws {
        let panel = makeAssistantPanel()

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 320, height: 460)
        TerminalAgentTraceNotification.post(
            runtimeID: "term_1",
            title: "prod@example.com",
            event: AgentTraceEvent(
                requestID: "req-policy-trace",
                state: .approved,
                message: "已按全局策略自动放行",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "environment": "production",
                    "aiExecutionPolicy": "readOnlyAuto",
                    "policyDecision": "autoAllowed"
                ]
            )
        )

        XCTAssertTrue(waitUntil { panel.statusTextForTesting == "" })
        XCTAssertEqual(panel.taskControlTextForTesting, "")
        XCTAssertFalse(panel.transcriptTextForTesting.contains("已确认，准备写入终端"))
        XCTAssertFalse(panel.transcriptTextForTesting.contains("执行："))
    }

    func testAssistantTaskControlHidesExecutionPolicyAuditMetadata() throws {
        let panel = makeAssistantPanel()

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 320, height: 460)
        TerminalAgentTraceNotification.post(
            runtimeID: "term_1",
            title: "prod@example.com",
            event: AgentTraceEvent(
                requestID: "req-policy-workspace",
                state: .running,
                message: "独立任务已启动，输出将同步显示",
                redactedCommand: "uptime",
                metadata: [
                    "executionMode": "backgroundTask",
                    "actorKind": AgentActorKind.builtInAI.rawValue,
                    "environment": "production",
                    "aiExecutionPolicy": "readOnlyAuto",
                    "policyDecision": "autoAllowed"
                ]
            )
        )

        XCTAssertTrue(waitUntil {
            panel.transcriptTextForTesting.contains("终端 · prod@example.com")
                && panel.transcriptTextForTesting.contains("$ uptime")
        })
        XCTAssertFalse(panel.taskControlTextForTesting.contains("生产环境"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("只读自动"))
        XCTAssertFalse(panel.taskControlTextForTesting.contains("自动放行"))
    }

    func testAssistantPanelDoesNotExpandInspectorWidthForLongErrorText() throws {
        let longToken = String(repeating: "DecodingErrorDataCorruptedUnexpectedCharacterAroundLineOneColumnOne", count: 8)
        let panel = makeAssistantPanel(provider: ThrowingAIAssistantProvider(error: LongAIError(message: longToken)))

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 300, height: 520)
        panel.setQuestionForTesting("你帮我看下这台服务器上有什么项目")
        panel.performAskForTesting()
        panel.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(waitUntil { panel.messageTextForTesting.contains(longToken) })
        XCTAssertLessThanOrEqual(panel.view.fittingSize.width, 320)
        XCTAssertLessThanOrEqual(
            panel.messageLabelAlignmentRectForTesting.width,
            panel.conversationContainerFrameForTesting.width + 1
        )
        XCTAssertLessThanOrEqual(
            panel.messageLabelAlignmentRectForTesting.maxX,
            panel.conversationContainerFrameForTesting.maxX + 1
        )
    }

    func testAssistantPanelDoesNotExpandInspectorWidthForLongAutomaticCommandText() throws {
        let longCommand = String(repeating: "journalctl--no-pager--unit=very-long-stacio-service-name ", count: 8)
        let execution = RecordingAgentCommandExecutor()
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(
                message: "建议先查看服务日志。",
                commandProposals: [
                    AgentCommandProposal(
                        id: "proposal-long",
                        command: longCommand,
                        explanation: String(repeating: "查看这个服务的日志输出", count: 8),
                        risk: .readOnly,
                        state: .proposed
                    )
                ]
            )
        )
        let panel = makeAssistantPanel(
            provider: provider,
            executionCoordinator: execution,
            settingsStore: makeSettingsStore(autoRunProposedCommands: false)
        )

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 300, height: 520)
        panel.setQuestionForTesting("帮我看服务日志")
        panel.performAskForTesting()
        panel.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })
        XCTAssertEqual(execution.requests.count, 0)
        XCTAssertEqual(panel.commandCardCountForTesting, 1)
        XCTAssertLessThanOrEqual(panel.view.fittingSize.width, 320)
        XCTAssertLessThanOrEqual(panel.commandCardsStackFrameForTesting.width, panel.view.bounds.width)
    }

    func testCommandCardExposesEnhancedHighlightSummaryForOpsCommand() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(
                message: "建议查看容器状态。",
                commandProposals: [
                    AgentCommandProposal(
                        id: "proposal-docker",
                        command: "docker compose ps --format json",
                        explanation: "查看 compose 服务状态",
                        risk: .readOnly,
                        state: .proposed
                    )
                ]
            )
        )
        let panel = makeAssistantPanel(provider: provider, settingsStore: makeSettingsStore(autoRunProposedCommands: false))

        panel.loadView()
        panel.view.frame = NSRect(x: 0, y: 0, width: 360, height: 520)
        panel.setQuestionForTesting("帮我看容器")
        panel.performAskForTesting()

        XCTAssertTrue(waitUntil { panel.commandCardCountForTesting == 1 })
        let cardText = panel.commandCardTextForTesting(at: 0)
        XCTAssertTrue(cardText.contains("命令：docker"))
        XCTAssertTrue(cardText.contains("子命令：compose, ps"))
        XCTAssertTrue(cardText.contains("参数：--format"))
    }

    func testInspectorShowsInjectedAIAssistantPanelAsSection() throws {
        let panel = makeAssistantPanel()
        let inspector = InspectorViewController(
            transferHistoryStore: NoOpSCPTransferHistoryStore(),
            aiAssistantViewController: panel
        )

        inspector.loadView()

        XCTAssertEqual(inspector.sectionLabelsForTesting, ["文件", "隧道", "浏览器", "诊断", "宏", "历史命令", "AI"])
        guard let aiIndex = inspector.sectionLabelsForTesting.firstIndex(of: L10n.AI.title) else {
            return XCTFail("expected AI inspector section")
        }
        inspector.selectSectionForTesting(aiIndex)
        XCTAssertTrue(inspector.selectedContentViewControllerForTesting === panel)
    }

    func testAssistantBuildsTerminalContextAndProposesCommand() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(
                message: "可以先看系统负载。",
                proposedCommand: "uptime"
            )
        )
        let coordinator = AIAssistantCoordinator(
            provider: provider,
            executionCoordinator: RecordingAgentCommandExecutor()
        )

        let response = try coordinator.ask(
            question: "这台机器卡吗？",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: "load average: 2.0"
            )
        )

        XCTAssertEqual(response.proposedCommand, "uptime")
        XCTAssertTrue(provider.requests[0].context.recentTranscript.contains("load average"))
    }

    func testAssistantContextRespectsTranscriptToggleAndKeepsSmallContextVerbatim() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "已分析", proposedCommand: nil)
        )
        let store = makeSettingsStore(
            autoRunProposedCommands: true,
            modelContextCharacterLimit: 26
        )
        store.update { settings in
            settings.aiIncludeRecentTerminalTranscript = true
        }
        let coordinator = AIAssistantCoordinator(
            provider: provider,
            executionCoordinator: RecordingAgentCommandExecutor(),
            settingsStore: store
        )

        _ = try coordinator.ask(
            question: "解释最近输出",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: "short output"
            )
        )

        XCTAssertEqual(provider.requests[0].context.recentTranscript, "short output")

        store.update { settings in
            settings.aiIncludeRecentTerminalTranscript = false
        }

        _ = try coordinator.ask(
            question: "解释最近输出",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: "sensitive terminal output"
            )
        )

        XCTAssertEqual(provider.requests[1].context.recentTranscript, "")
    }

    func testAssistantContextAutoCompressesLargeTranscriptBeforeProviderRequest() throws {
        let provider = RecordingAIAssistantProvider(
            response: AIAssistantResponse(message: "已分析", proposedCommand: nil)
        )
        let store = makeSettingsStore(
            autoRunProposedCommands: true,
            modelContextCharacterLimit: 260
        )
        store.update { settings in
            settings.aiIncludeRecentTerminalTranscript = true
        }
        let coordinator = AIAssistantCoordinator(
            provider: provider,
            executionCoordinator: RecordingAgentCommandExecutor(),
            settingsStore: store
        )

        _ = try coordinator.ask(
            question: "解释最近输出",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: [
                    "first boot line",
                    "docker failed to pull image",
                    String(repeating: "middle line\n", count: 30),
                    "last important output"
                ].joined(separator: "\n")
            )
        )

        let transcript = provider.requests[0].context.recentTranscript
        XCTAssertLessThanOrEqual(transcript.count, 260)
        XCTAssertTrue(transcript.contains("自动上下文压缩"))
        XCTAssertTrue(transcript.contains("docker failed"))
        XCTAssertTrue(transcript.contains("last important output"))
    }

    func testAssistantExecutesProposedCommandThroughAgentExecutionCoordinator() throws {
        let execution = RecordingAgentCommandExecutor()
        let coordinator = AIAssistantCoordinator(
            provider: RecordingAIAssistantProvider(response: .init(message: "执行", proposedCommand: "pwd")),
            executionCoordinator: execution
        )

        try coordinator.executeProposedCommand(
            "pwd",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            )
        )

        XCTAssertEqual(execution.requests.count, 1)
        guard case .runCommand(let run) = execution.requests[0].action else {
            return XCTFail("expected run command")
        }
        XCTAssertEqual(run.target, .runtimeID("term_1"))
        XCTAssertEqual(run.command, "pwd")
    }

    func testAssistantExecutesProposedCommandWithExistingTaskRequestID() throws {
        let execution = RecordingAgentCommandExecutor()
        let coordinator = AIAssistantCoordinator(
            provider: RecordingAIAssistantProvider(response: .init(message: "执行", proposedCommand: "docker ps")),
            executionCoordinator: execution
        )

        try coordinator.executeProposedCommand(
            "docker ps",
            context: AITerminalContext(
                runtimeID: "term_1",
                title: "dev@example.com",
                currentDirectory: "/srv/app",
                recentTranscript: ""
            ),
            requestID: "req-existing-task"
        )

        XCTAssertEqual(execution.requests.map(\.id), ["req-existing-task"])
        guard case .runCommand(let run) = execution.requests[0].action else {
            return XCTFail("expected run command")
        }
        XCTAssertEqual(run.target, .runtimeID("term_1"))
        XCTAssertEqual(run.command, "docker ps")
    }

    private func makeAIRequest() -> AIAssistantRequest {
        AIAssistantRequest(
            question: "帮我看一下",
            context: AITerminalContext(
                runtimeID: "term_ssh",
                title: "root@centos7",
                currentDirectory: "/root",
                recentTranscript: ""
            )
        )
    }

    private func chatCompletionBody(message: String) -> String {
        chatCompletionBody(rawContent: #"{"message":"\#(message)","commands":[]}"#)
    }

    private func chatCompletionBody(rawContent: String) -> String {
        let escapedContent = rawContent
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "choices": [
            {
              "message": {
                "content": "\(escapedContent)"
              }
            }
          ]
        }
        """
    }

    private func chatStreamDataLine(content: String) -> String {
        let escapedContent = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        data: {"choices":[{"delta":{"content":"\(escapedContent)"}}]}

        """
    }

    private func makeAssistantPanel(
        provider: AIAssistantProviding = RecordingAIAssistantProvider(response: .init(message: "", proposedCommand: nil)),
        executionCoordinator: AgentCommandExecuting? = nil,
        settingsStore: AppSettingsStore? = nil,
        taskRecorder: AgentTaskRecording? = nil,
        taskLister: AgentTaskListing? = nil,
        conversationHistoryStore: AIAssistantConversationHistoryStoring? = nil,
        recentTranscript: String = "",
        contextProvider: ((String?) -> AITerminalContext?)? = nil,
        attachmentPicker: @escaping () -> [URL] = { [] },
        currentRemoteFileAttachmentProvider: (() throws -> AIAssistantAttachment)? = nil,
        currentRemoteFileAttachmentAvailabilityProvider: (() -> Bool)? = nil,
        modelSelectionSession: AIModelSelectionSession = AIModelSelectionSession(),
        localAgentToolResolver: LocalAgentToolResolving = StaticLocalAgentToolResolver(paths: [:]),
        localAgentProcessLauncherFactory: @escaping () -> LocalTerminalProcessLaunching = {
            RecordingLocalAgentProcessLauncher()
        }
    ) -> AIAssistantPanelViewController {
        let resolvedSettingsStore = settingsStore ?? makeSettingsStore(autoRunProposedCommands: true)
        return AIAssistantPanelViewController(
            coordinator: AIAssistantCoordinator(
                provider: provider,
                executionCoordinator: executionCoordinator ?? RecordingAgentCommandExecutor(),
                settingsStore: resolvedSettingsStore,
                modelSelectionSession: modelSelectionSession
            ),
            contextProvider: contextProvider ?? { _ in
                AITerminalContext(
                    runtimeID: "term_1",
                    title: "dev@example.com",
                    currentDirectory: "/srv/app",
                    recentTranscript: recentTranscript
                )
            },
            settingsStore: resolvedSettingsStore,
            modelSelectionSession: modelSelectionSession,
            taskRecorder: taskRecorder,
            taskLister: taskLister,
            conversationHistoryStore: conversationHistoryStore,
            attachmentPicker: attachmentPicker,
            currentRemoteFileAttachmentProvider: currentRemoteFileAttachmentProvider,
            currentRemoteFileAttachmentAvailabilityProvider: currentRemoteFileAttachmentAvailabilityProvider,
            localAgentToolResolver: localAgentToolResolver,
            localAgentProcessLauncherFactory: localAgentProcessLauncherFactory
        )
    }

    private func makeModelProvider(
        id: UUID,
        name: String,
        modelIDs: [String],
        defaultModelID: String
    ) -> AIProviderConfiguration {
        AIProviderConfiguration(
            id: id,
            profile: .openAICompatible,
            displayName: name,
            baseURL: "https://\(id.uuidString.lowercased()).example/v1",
            models: modelIDs.map {
                AIProviderModelConfiguration(
                    id: $0,
                    isEnabled: true,
                    isManual: false,
                    wasReturnedByLatestCatalog: true
                )
            },
            defaultModelID: defaultModelID,
            compatibilityProtocol: .chatCompletions,
            maxRetryCount: 1,
            requestTimeoutSeconds: 45,
            userAgent: "Stacio",
            isEnabled: true,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil
        )
    }

    private func makeFactoryProvider(
        profile: AIProviderProfile = .openAICompatible,
        baseURL: String,
        modelID: String = "ops-model",
        apiKey: String?,
        maxRetryCount: Int = 1,
        requestTimeoutSeconds: Int = 45,
        userAgent: String = "Stacio",
        compatibilityProtocol: AICompatibilityProtocolPreference = .chatCompletions,
        transport: AIAssistantHTTPTransport
    ) -> AIAssistantProviding {
        let providerID = UUID()
        let provider = AIProviderConfiguration(
            id: providerID,
            profile: profile,
            displayName: profile.displayName,
            baseURL: baseURL,
            models: [
                AIProviderModelConfiguration(
                    id: modelID,
                    isEnabled: true,
                    isManual: false,
                    wasReturnedByLatestCatalog: true
                )
            ],
            defaultModelID: modelID,
            compatibilityProtocol: compatibilityProtocol,
            maxRetryCount: maxRetryCount,
            requestTimeoutSeconds: requestTimeoutSeconds,
            userAgent: userAgent,
            isEnabled: true,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil
        )
        return AIAssistantProviderFactory.makeProvider(
            settings: AppSettings(
                aiProviderSettings: AIProviderSettingsEnvelope(
                    aiProviders: [provider],
                    defaultAIProviderID: providerID
                )
            ),
            requestedSelection: nil,
            apiKeyProvider: { requestedProviderID in
                requestedProviderID == providerID ? apiKey : nil
            },
            transport: transport
        )
    }

    private func makePanelCatalogProvider(
        baseURL: String,
        maxRetryCount: Int = 1,
        requestTimeoutSeconds: Int = 45,
        userAgent: String = "Stacio"
    ) -> AIProviderConfiguration {
        AIProviderConfiguration(
            id: UUID(),
            profile: .openAICompatible,
            displayName: "Catalog Test",
            baseURL: baseURL,
            models: [],
            defaultModelID: nil,
            compatibilityProtocol: .chatCompletions,
            maxRetryCount: maxRetryCount,
            requestTimeoutSeconds: requestTimeoutSeconds,
            userAgent: userAgent,
            isEnabled: true,
            lastVerifiedAt: nil,
            lastModelSyncAt: nil
        )
    }

    private func makeAgentTaskSessionRecord(
        id: String,
        requestID: String,
        runtimeID: String,
        title: String,
        command: String,
        actorKind: String = AgentActorKind.builtInAI.rawValue,
        actorName: String = "Stacio AI"
    ) -> AgentTaskSessionRecord {
        AgentTaskSessionRecord(
            id: id,
            requestId: requestID,
            actorKind: actorKind,
            actorName: actorName,
            targetRuntimeId: runtimeID,
            targetTitle: title,
            state: "completed",
            userPrompt: "查看任务",
            assistantMessage: "建议执行命令。",
            createdAt: "2026-06-06T00:00:00Z",
            updatedAt: "2026-06-06T00:01:00Z",
            proposals: [
                AgentTaskProposalRecord(
                    id: "\(id)-proposal",
                    command: command,
                    explanation: "检查状态",
                    risk: "readOnly",
                    state: "completed",
                    sortOrder: 0,
                    createdAt: "2026-06-06T00:00:00Z",
                    updatedAt: "2026-06-06T00:01:00Z"
                )
            ]
        )
    }

    private func makeHistoryRecord(
        runtimeID: String,
        role: AIConversationHistoryRole,
        content: String,
        requestID: String? = nil
    ) -> AIConversationHistoryItemRecord {
        AIConversationHistoryItemRecord(
            id: UUID().uuidString,
            runtimeId: runtimeID,
            role: role.rawValue,
            content: content,
            requestId: requestID,
            createdAt: "2026-07-02T00:00:00Z"
        )
    }

    private func makeSettingsStore(
        autoRunProposedCommands: Bool,
        modelContextCharacterLimit: Int = AIModelCapabilityConfiguration.defaultContextCharacterLimit
    ) -> AppSettingsStore {
        let defaults = UserDefaults(suiteName: "StacioAIPanelSettings-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        var provider = makeModelProvider(
            id: UUID(),
            name: "Test Provider",
            modelIDs: ["test-model"],
            defaultModelID: "test-model"
        )
        provider.models[0].capabilities = AIModelCapabilityConfiguration(
            contextCharacterLimit: modelContextCharacterLimit,
            contextCharacterLimitSource: .manual
        )
        try! store.saveAIProviderSettings(
            AIProviderSettingsEnvelope(
                aiProviders: [provider],
                defaultAIProviderID: provider.id
            )
        )
        store.update { settings in
            settings.aiAutoRunProposedCommands = autoRunProposedCommands
        }
        return store
    }

    private func makeUnconfiguredSettingsStore(autoRunProposedCommands: Bool) -> AppSettingsStore {
        let defaults = UserDefaults(suiteName: "StacioAIUnconfiguredPanelSettings-\(UUID().uuidString)")!
        let store = AppSettingsStore(defaults: defaults)
        store.update { settings in
            settings.aiAutoRunProposedCommands = autoRunProposedCommands
        }
        return store
    }
}

private struct StaticLocalAgentToolResolver: LocalAgentToolResolving {
    let paths: [LocalAgentTool: String]

    func executablePath(for tool: LocalAgentTool) -> String? {
        paths[tool]
    }
}

private final class MutableLocalAgentToolResolver: LocalAgentToolResolving {
    var paths: [LocalAgentTool: String]

    init(paths: [LocalAgentTool: String]) {
        self.paths = paths
    }

    func executablePath(for tool: LocalAgentTool) -> String? {
        paths[tool]
    }
}

private final class RecordingLocalAgentProcessLauncher: LocalTerminalProcessLaunching {
    private(set) var startedExecutable: String?
    private(set) var startedArgs: [String]?
    private(set) var startedEnvironment: [String]?
    private(set) var startedExecName: String?
    private(set) var startedCurrentDirectory: String?
    private(set) var startCount = 0
    private(set) var terminated = false
    var running = false

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool {
        running
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
        startedExecutable = executable
        startedArgs = args
        startedEnvironment = environment
        startedExecName = execName
        startedCurrentDirectory = currentDirectory
        running = true
    }

    func terminate(_ terminalView: LocalProcessTerminalView) {
        terminated = true
        running = false
    }

    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {}

    var startedEnvironmentDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: (startedEnvironment ?? []).compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        })
    }
}

private final class RecordingAIAssistantProvider: AIAssistantProviding {
    private let response: AIAssistantResponse
    private(set) var requests: [AIAssistantRequest] = []

    init(response: AIAssistantResponse) {
        self.response = response
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        requests.append(request)
        return response
    }
}

private final class SequencedPanelAIAssistantProvider: AIAssistantProviding {
    private let responses: [AIAssistantResponse]
    private(set) var requests: [AIAssistantRequest] = []

    init(responses: [AIAssistantResponse]) {
        self.responses = responses
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        requests.append(request)
        let index = min(requests.count - 1, responses.count - 1)
        return responses[index]
    }
}

private final class SequencedStreamingPanelAIAssistantProvider: AIAssistantProviding, AIAssistantStreamingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [(partials: [String], response: AIAssistantResponse)]
    private var requestCount = 0

    init(responses: [(partials: [String], response: AIAssistantResponse)]) {
        self.responses = responses
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        XCTFail("expected streaming path")
        return responses[0].response
    }

    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        let item = lock.withLock { () -> (partials: [String], response: AIAssistantResponse) in
            let index = min(requestCount, responses.count - 1)
            requestCount += 1
            return responses[index]
        }
        item.partials.forEach(onPartial)
        return item.response
    }
}

private final class SelectionSnapshottingAIAssistantProvider: AIAssistantProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let selectionSession: AIModelSelectionSession
    private let responses: [AIAssistantResponse]
    private let onFirstRequest: () -> Void
    private var recordedSelections: [AIModelSelection?] = []

    init(
        selectionSession: AIModelSelectionSession,
        responses: [AIAssistantResponse],
        onFirstRequest: @escaping () -> Void
    ) {
        self.selectionSession = selectionSession
        self.responses = responses
        self.onFirstRequest = onFirstRequest
    }

    var selectionSnapshots: [AIModelSelection?] {
        lock.withLock { recordedSelections }
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        let index = lock.withLock { () -> Int in
            recordedSelections.append(selectionSession.snapshot())
            return recordedSelections.count - 1
        }
        if index == 0 {
            onFirstRequest()
        }
        return responses[min(index, responses.count - 1)]
    }
}

private final class SelectionSnapshottingResultAIAssistantProvider: AIAssistantProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let selectionSession: AIModelSelectionSession
    private let results: [Result<AIAssistantResponse, Error>]
    private var recordedSelections: [AIModelSelection?] = []

    init(
        selectionSession: AIModelSelectionSession,
        results: [Result<AIAssistantResponse, Error>]
    ) {
        self.selectionSession = selectionSession
        self.results = results
    }

    var selectionSnapshots: [AIModelSelection?] {
        lock.withLock { recordedSelections }
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        let index = lock.withLock { () -> Int in
            recordedSelections.append(selectionSession.snapshot())
            return recordedSelections.count - 1
        }
        return try results[min(index, results.count - 1)].get()
    }
}

private final class DelayedSequencedPanelAIAssistantProvider: AIAssistantProviding {
    private let responses: [(response: AIAssistantResponse, delay: TimeInterval)]
    private(set) var requests: [AIAssistantRequest] = []

    init(responses: [(AIAssistantResponse, TimeInterval)]) {
        self.responses = responses.map { (response: $0.0, delay: $0.1) }
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        requests.append(request)
        let index = min(requests.count - 1, responses.count - 1)
        let entry = responses[index]
        if entry.delay > 0 {
            Thread.sleep(forTimeInterval: entry.delay)
        }
        return entry.response
    }
}

private struct ThrowingAIAssistantProvider: AIAssistantProviding {
    let error: Error

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        throw error
    }
}

private struct DelayedAIAssistantProvider: AIAssistantProviding {
    let response: AIAssistantResponse
    let delay: TimeInterval

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        Thread.sleep(forTimeInterval: delay)
        return response
    }
}

private struct LongAIError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class RecordingAgentTaskStore: AgentTaskRecording, AgentTaskListing {
    struct Record {
        let session: AgentTaskSession
        let requestID: String
        let userPrompt: String
        let assistantMessage: String
    }

    private(set) var records: [Record] = []
    var listedSessions: [AgentTaskSessionRecord] = []
    var nextRequestID: String?
    private(set) var listLimits: [UInt32] = []
    private(set) var listedRequestIDs: [String] = []

    func recordAgentTaskSession(
        _ session: AgentTaskSession,
        requestID: String,
        userPrompt: String,
        assistantMessage: String
    ) throws -> AgentTaskSessionRecord {
        let storedRequestID = nextRequestID ?? requestID
        records.append(
            Record(
                session: session,
                requestID: storedRequestID,
                userPrompt: userPrompt,
                assistantMessage: assistantMessage
            )
        )
        return AgentTaskSessionRecord(
            id: session.id,
            requestId: storedRequestID,
            actorKind: "builtInAI",
            actorName: "Stacio AI",
            targetRuntimeId: session.targetRuntimeID,
            targetTitle: session.targetTitle,
            state: session.state.rawValue,
            userPrompt: userPrompt,
            assistantMessage: assistantMessage,
            createdAt: "2026-06-06T00:00:00Z",
            updatedAt: "2026-06-06T00:00:00Z",
            proposals: []
        )
    }

    func listAgentTaskSessions(limit: UInt32) throws -> [AgentTaskSessionRecord] {
        listLimits.append(limit)
        return Array(listedSessions.prefix(Int(limit)))
    }

    func listAgentTaskSessions(requestID: String) throws -> [AgentTaskSessionRecord] {
        listedRequestIDs.append(requestID)
        return listedSessions.filter { $0.requestId == requestID }
    }
}

private final class RecordingAIConversationHistoryStore: AIAssistantConversationHistoryStoring {
    struct AppendedItem {
        let runtimeID: String
        let role: AIConversationHistoryRole
        let content: String
        let requestID: String?
    }

    var listedItems: [AIConversationHistoryItemRecord] = []
    private(set) var listedRuntimeIDs: [String] = []
    private(set) var appendedItems: [AppendedItem] = []
    private(set) var clearCount = 0

    func appendConversationHistoryItem(
        runtimeID: String,
        role: AIConversationHistoryRole,
        content: String,
        requestID: String?
    ) throws -> AIConversationHistoryItemRecord {
        appendedItems.append(
            AppendedItem(
                runtimeID: runtimeID,
                role: role,
                content: content,
                requestID: requestID
            )
        )
        let record = AIConversationHistoryItemRecord(
            id: UUID().uuidString,
            runtimeId: runtimeID,
            role: role.rawValue,
            content: content,
            requestId: requestID,
            createdAt: "2026-07-02T00:00:00Z"
        )
        listedItems.append(record)
        return record
    }

    func listConversationHistory(runtimeID: String) throws -> [AIConversationHistoryItemRecord] {
        listedRuntimeIDs.append(runtimeID)
        return listedItems.filter { $0.runtimeId == runtimeID }
    }

    func clearConversationHistory() throws {
        clearCount += 1
        listedItems.removeAll()
    }
}

private final class RecordingAIAssistantHTTPTransport: AIAssistantHTTPTransport {
    private let responseBody: String
    private(set) var requests: [URLRequest] = []

    init(responseBody: String) {
        self.responseBody = responseBody
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            Data(responseBody.utf8),
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

private final class RoutingAIAssistantHTTPTransport: AIAssistantHTTPTransport {
    private let routes: [String: (statusCode: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(routes: [String: (Int, String)]) {
        self.routes = routes.mapValues { (statusCode: $0.0, body: $0.1) }
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let route = routes[path] ?? (404, "{\"error\":\"not found\"}")
        return (
            Data(route.body.utf8),
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: route.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

private final class SequencedAIAssistantHTTPTransport: AIAssistantHTTPTransport {
    private let responses: [(statusCode: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Int, String)]) {
        self.responses = responses.map { (statusCode: $0.0, body: $0.1) }
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let index = min(requests.count - 1, responses.count - 1)
        let response = responses[index]
        return (
            Data(response.body.utf8),
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }
}

private final class StreamingAIAssistantHTTPTransport: AIAssistantHTTPTransport {
    private let chunks: [Data]
    private(set) var requests: [URLRequest] = []
    private(set) var streamRequests: [URLRequest] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        throw AIAssistantProviderError.invalidResponse
    }

    func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse {
        streamRequests.append(request)
        for chunk in chunks {
            onChunk(chunk)
        }
        return HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
    }
}

private final class UnsupportedStreamingAIAssistantHTTPTransport: AIAssistantHTTPTransport {
    private let responseBody: String
    private(set) var requests: [URLRequest] = []
    private(set) var streamRequests: [URLRequest] = []

    init(responseBody: String) {
        self.responseBody = responseBody
    }

    func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            Data(responseBody.utf8),
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.example.com")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func stream(
        _ request: URLRequest,
        onChunk: @escaping (Data) -> Void
    ) async throws -> HTTPURLResponse {
        streamRequests.append(request)
        throw AIAssistantProviderError.streamUnsupported
    }
}

private final class HangingStreamingAIAssistantProvider: AIAssistantProviding, AIAssistantStreamingProviding, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "StacioTests.HangingStreamingAIAssistantProvider")
    private var _started = false
    private var _cancelled = false
    private var _requests: [AIAssistantRequest] = []
    var requests: [AIAssistantRequest] {
        stateQueue.sync { _requests }
    }

    var started: Bool {
        stateQueue.sync { _started }
    }

    var cancelled: Bool {
        stateQueue.sync { _cancelled }
    }

    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        XCTFail("expected streaming path")
        return AIAssistantResponse(message: "", proposedCommand: nil)
    }

    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        stateQueue.sync {
            _started = true
            _requests.append(request)
        }
        onPartial("正在生成")
        do {
            while Task.isCancelled == false {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        } catch {
            markCancelled()
            throw CancellationError()
        }
        markCancelled()
        throw CancellationError()
    }

    private func markCancelled() {
        stateQueue.sync {
            _cancelled = true
        }
    }
}

@MainActor
private final class RecordingAgentCommandExecutor: AgentCommandExecuting, AgentTaskControlling {
    private(set) var requests: [AgentBridgeRequest] = []
    private(set) var commands: [String] = []
    private(set) var cancelledRequestIDs: [String] = []
    private(set) var pausedRequestIDs: [String] = []
    private(set) var takenOverRequestIDs: [String] = []
    private(set) var confirmedRequestIDs: [String] = []
    var cancelEvents: [String: AgentTraceEvent] = [:]
    var pauseEvents: [String: AgentTraceEvent] = [:]
    var takeOverEvents: [String: AgentTraceEvent] = [:]
    var confirmEvents: [String: AgentTraceEvent] = [:]
    private var originalEventRequestIDsByRequestID: [String: String] = [:]
    private let events: [AgentTraceEvent]
    private let eventsByRequestID: [String: [AgentTraceEvent]]
    private let eventsByCommand: [String: [AgentTraceEvent]]

    init(
        events: [AgentTraceEvent] = [],
        eventsByRequestID: [String: [AgentTraceEvent]] = [:],
        eventsByCommand: [String: [AgentTraceEvent]] = [:]
    ) {
        self.events = events
        self.eventsByRequestID = eventsByRequestID
        self.eventsByCommand = eventsByCommand
    }

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        requests.append(request)
        if case .runCommand(let run) = request.action {
            commands.append(run.command)
            return remapEvents(eventsByRequestID[request.id] ?? eventsByCommand[run.command] ?? events, requestID: request.id)
        }
        return remapEvents(eventsByRequestID[request.id] ?? events, requestID: request.id)
    }

    private func remapEvents(_ source: [AgentTraceEvent], requestID: String) -> [AgentTraceEvent] {
        if let originalRequestID = source.first?.requestID,
           originalRequestID != requestID {
            originalEventRequestIDsByRequestID[requestID] = originalRequestID
        }
        return source.map { event in
            AgentTraceEvent(
                requestID: requestID,
                state: event.state,
                message: event.message,
                redactedCommand: event.redactedCommand,
                metadata: event.metadata
            )
        }
    }

    func cancelTask(requestID: String) -> AgentTraceEvent? {
        cancelledRequestIDs.append(requestID)
        return remapControlEvent(cancelEvents[requestID] ?? originalEventRequestIDsByRequestID[requestID].flatMap { cancelEvents[$0] }, requestID: requestID)
    }

    func pauseTask(requestID: String) -> AgentTraceEvent? {
        pausedRequestIDs.append(requestID)
        return remapControlEvent(pauseEvents[requestID] ?? originalEventRequestIDsByRequestID[requestID].flatMap { pauseEvents[$0] }, requestID: requestID)
    }

    func takeOverTask(requestID: String) -> AgentTraceEvent? {
        takenOverRequestIDs.append(requestID)
        return remapControlEvent(takeOverEvents[requestID] ?? originalEventRequestIDsByRequestID[requestID].flatMap { takeOverEvents[$0] }, requestID: requestID)
    }

    func confirmTaskComplete(requestID: String) -> AgentTraceEvent? {
        confirmedRequestIDs.append(requestID)
        return remapControlEvent(
            confirmEvents[requestID]
                ?? originalEventRequestIDsByRequestID[requestID].flatMap { confirmEvents[$0] },
            requestID: requestID
        )
    }

    private func remapControlEvent(_ event: AgentTraceEvent?, requestID: String) -> AgentTraceEvent? {
        guard let event else { return nil }
        return AgentTraceEvent(
            requestID: requestID,
            state: event.state,
            message: event.message,
            redactedCommand: event.redactedCommand,
            metadata: event.metadata
        )
    }
}

@MainActor
private final class StreamingRecordingAgentCommandExecutor: AgentCommandStreamingExecuting, AgentTaskControlling {
    private(set) var requests: [AgentBridgeRequest] = []
    private(set) var streamingRequestIDs: [String] = []
    private let events: [AgentTraceEvent]

    init(events: [AgentTraceEvent]) {
        self.events = events
    }

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        requests.append(request)
        return []
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        requests.append(request)
        streamingRequestIDs.append(request.id)
        let remappedEvents = events.map { event in
            AgentTraceEvent(
                requestID: request.id,
                state: event.state,
                message: event.message,
                redactedCommand: event.redactedCommand,
                metadata: event.metadata
            )
        }
        remappedEvents.forEach(emit)
        return remappedEvents
    }

    func cancelTask(requestID: String) -> AgentTraceEvent? {
        nil
    }
}

@MainActor
private extension NSView {
    func firstSubview(withIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}
