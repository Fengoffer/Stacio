import AppKit
import StacioAgentBridge
import SwiftTerm
import XCTest
@testable import StacioApp

@MainActor
final class TerminalPaneViewControllerTests: XCTestCase {
    func testTerminalPaneLoadsSwiftTermView() {
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            autoStartProcess: false
        )

        controller.loadView()

        XCTAssertTrue(controller.terminalView.superview === controller.view)
        XCTAssertEqual(controller.runtimeID, "term_test")
        XCTAssertEqual(controller.shellPath, "/bin/zsh")
    }

    func testLocalTerminalDragSelectionDoesNotMoveWindow() {
        let terminalView = StacioLocalTerminalView(frame: .zero)

        XCTAssertFalse(terminalView.mouseDownCanMoveWindow)
    }

    func testLocalTerminalEnablesCommandClickImplicitLinks() {
        let terminalView = StacioLocalTerminalView(frame: .zero)

        XCTAssertEqual(terminalView.linkReporting, .implicit)
        XCTAssertEqual(terminalView.linkHighlightMode, .hoverWithModifier)
    }

    func testLocalTerminalStartsShellWithOSC7IntegrationEnvironment() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher
        )

        controller.loadView()
        controller.viewDidAppear()

        XCTAssertEqual(launcher.startedEnvironmentDictionary["STACIO_OSC7_ENABLED"], "1")
        XCTAssertTrue(launcher.startedEnvironmentDictionary["STACIO_OSC7_BOOTSTRAP"]?.contains("precmd_functions+=") == true)
        XCTAssertTrue(launcher.startedArgs?.joined(separator: " ").contains("STACIO_OSC7_BOOTSTRAP") == true)
        XCTAssertNil(launcher.startedEnvironmentDictionary["PS1"])
    }

    func testLocalTerminalLaunchDoesNotDependOnShellEnvironmentVariable() throws {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher
        )

        controller.loadView()
        controller.viewDidAppear()

        let startupCommand = try XCTUnwrap(launcher.startedArgs?.last)
        XCTAssertFalse(startupCommand.contains("$SHELL"))
        XCTAssertTrue(startupCommand.contains(#"exec "/bin/zsh" -l"#))
    }

    func testLocalOSC7BootstrapUsesShellSpecificSyntax() throws {
        let zshScript = try XCTUnwrap(TerminalOSC7ShellIntegration.localBootstrapScript(shellName: "zsh"))
        let bashScript = try XCTUnwrap(TerminalOSC7ShellIntegration.localBootstrapScript(shellName: "bash"))
        let fishScript = try XCTUnwrap(TerminalOSC7ShellIntegration.localBootstrapScript(shellName: "fish"))

        XCTAssertTrue(zshScript.contains("precmd_functions+="))
        XCTAssertFalse(zshScript.contains("fish_prompt"))
        XCTAssertTrue(bashScript.contains("PROMPT_COMMAND="))
        XCTAssertFalse(bashScript.contains("fish_prompt"))
        XCTAssertTrue(fishScript.contains("function fish_prompt"))
        XCTAssertFalse(fishScript.contains("PROMPT_COMMAND="))
        XCTAssertFalse(fishScript.contains("precmd_functions+="))
        try assertShellAcceptsScript(executable: "/bin/zsh", arguments: ["-n"], script: zshScript)
        try assertShellAcceptsScript(executable: "/bin/bash", arguments: ["-n"], script: bashScript)
    }

    func testLocalTerminalTracksOSC7HostCurrentDirectoryUpdates() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/Users/mac/project")

        XCTAssertEqual(controller.currentLocalDirectory, "/Users/mac/project")
    }

    func testLocalTerminalContextMenuAsksAIWithSelectedText() throws {
        var request: TerminalAIContextRequest?
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )
        controller.onAIContextRequest = { request = $0 }

        controller.loadView()
        let menu = controller.terminalContextMenuForTesting(selectedText: "permission denied")
        XCTAssertEqual(menu.items.map(\.title), ["粘贴", "询问 AI", "解释选中内容"])

        let explainItem = try XCTUnwrap(menu.items.first { $0.title == "解释选中内容" })
        let action = try XCTUnwrap(explainItem.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: explainItem.target, from: explainItem))

        XCTAssertEqual(request, TerminalAIContextRequest(runtimeID: "term_local", selectedText: "permission denied"))
    }

    func testAgentTraceRemainsDataOnlyAndDoesNotCreateTerminalOverlay() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.appendAgentTraceForTesting(
            requestID: "req-1",
            state: .running,
            message: "Codex 正在执行 uptime",
            redactedCommand: "uptime"
        )

        XCTAssertEqual(launcher.sentInput, [])
        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("Codex 正在执行 uptime"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTrace.openTask.req-1"))
    }

    func testAgentTraceDoesNotAddViewsAboveTerminal() throws {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )

        controller.loadView()
        controller.appendAgentTraceForTesting(
            requestID: "req-hit-test",
            state: .running,
            message: "Codex 正在执行 uptime",
            redactedCommand: "uptime"
        )

        XCTAssertTrue(controller.terminalView.superview === controller.view)
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTrace.openTask.req-hit-test"))
    }

    func testAgentTraceDoesNotExposeOldOpenTaskButton() throws {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.appendAgentTraceForTesting(
            requestID: "req-open-task",
            state: .running,
            message: "Codex 正在执行 uptime",
            redactedCommand: "uptime"
        )

        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTrace.openTask.req-open-task"))
        XCTAssertEqual(launcher.sentInput, [])
    }

    func testAgentTraceDoesNotRenderBoundedStateAndRiskOverlay() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )

        controller.loadView()
        for index in 0..<8 {
            controller.appendAgentTraceForTesting(
                requestID: "req-\(index)",
                state: index == 7 ? .running : .queued,
                message: "AI 步骤 \(index)",
                redactedCommand: index == 7 ? "rm -rf /tmp/build" : "uptime"
            )
        }

        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("running"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
    }

    func testAgentTraceDoesNotRenderRequestTimelineProgressInTerminalPane() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )

        controller.loadView()
        [
            (AgentTraceState.queued, "Codex 已排队"),
            (.awaitingApproval, "等待确认"),
            (.typing, "正在写入终端"),
            (.running, "命令已在终端执行")
        ].forEach { state, message in
            controller.appendAgentTraceForTesting(
                requestID: "req-follow",
                state: state,
                message: message,
                redactedCommand: "uptime"
            )
        }

        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("等待确认"))
        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("命令已在终端执行"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
    }

    func testAgentTraceBackgroundMetadataStaysInDataLayerOnly() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )

        controller.loadView()
        controller.appendAgentTraceForTesting(
            requestID: "req-background",
            state: .waitingForOutput,
            message: "已创建独立执行终端，等待输出",
            redactedCommand: "uptime",
            metadata: [
                "executionMode": "backgroundTask",
                "taskRuntimeID": "agent_bg_1"
            ]
        )

        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("已创建独立执行终端"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
    }

    func testAgentTraceExecutionPolicyMetadataStaysInDataLayerOnly() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )

        controller.loadView()
        controller.appendAgentTraceForTesting(
            requestID: "req-policy",
            state: .approved,
            message: "已按全局策略自动放行",
            redactedCommand: "uptime",
            metadata: [
                "executionMode": "backgroundTask",
                "environment": "production",
                "aiExecutionPolicy": "readOnlyAuto",
                "policyDecision": "autoAllowed",
                "targetTitle": "prod@example.com"
            ]
        )

        XCTAssertTrue(controller.agentTraceSnapshotForTesting.contains("已按全局策略自动放行"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTraceOverlay"))
        XCTAssertNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.agentTrace.openTask.req-policy"))
    }

    func testLocalTerminalShowsEnhancedCommandHintForTypedOpsCommand() {
        let suiteName = "StacioLocalCommandHint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("docker compose up -d\n".utf8))
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("命令：docker"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("compose"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("up"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("网络"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("docker compose up -d"))
    }

    func testLocalTerminalCommandHintKeepsQuotedFlagValuesReadable() {
        let suiteName = "StacioLocalQuotedCommandHint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        let commandBytes = Array(#"journalctl --since "2 hours ago" -u sshd --no-pager"#.utf8) + [10]
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(commandBytes)
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("命令：journalctl"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("参数：--since, -u, --no-pager"))
        XCTAssertFalse(controller.commandHintVisibleTextForTesting.contains("子命令：hours"))
        XCTAssertFalse(controller.commandHintVisibleTextForTesting.contains("子命令：ago"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains(#"journalctl --since "2 hours ago" -u sshd --no-pager"#))
    }

    func testLocalTerminalCommandHintHighlightsKubectlMutatingSubcommands() {
        let suiteName = "StacioLocalKubectlMutatingHint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("kubectl -n prod patch deployment api -p '{}'\n".utf8))
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("命令：kubectl"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("patch"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("网络"))
        XCTAssertFalse(controller.commandHintVisibleTextForTesting.contains("子命令：prod"))
    }

    func testLocalTerminalCommandHintHighlightsIaCAndServiceCommands() {
        let suiteName = "StacioLocalIaCCommandHint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("terraform apply -auto-approve\n".utf8))
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("命令：terraform"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("apply"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("网络"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("terraform apply -auto-approve"))

        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("pm2 delete api\n".utf8))
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("命令：pm2"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("delete"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("危险"))
    }

    func testLocalTerminalCompletesMainstreamLinuxCommandWithTab() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("sys".utf8))
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("systemctl"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("Tab"))

        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([9]))

        XCTAssertEqual(
            launcher.sentInput.map { String(decoding: $0, as: UTF8.self) },
            ["temctl "]
        )
    }

    func testLocalTerminalReportsSubmittedCommandsFromUserInput() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )
        var submittedCommands: [(runtimeID: String, command: String)] = []
        controller.onCommandSubmitted = { pane, command in
            submittedCommands.append((pane.runtimeID, command))
        }

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("  git status  \n".utf8))
        )
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("\n".utf8))
        )

        XCTAssertEqual(submittedCommands.map(\.runtimeID), ["term_local"])
        XCTAssertEqual(submittedCommands.map(\.command), ["git status"])
    }

    func testLocalTerminalReportsSubmittedCommandsAfterShellTabCompletion() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )
        var submittedCommands: [String] = []
        controller.onCommandSubmitted = { _, command in
            submittedCommands.append(command)
        }

        controller.loadView()
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice(Array("cd /da".utf8)))
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([9]))
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice(Array("\n".utf8)))

        XCTAssertEqual(submittedCommands, ["cd /da"])
    }

    func testLocalTerminalReportsSubmittedCommandsFromProgrammaticInput() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )
        var submittedCommands: [String] = []
        controller.onCommandSubmitted = { _, command in
            submittedCommands.append(command)
        }

        controller.loadView()
        controller.sendInput(Array("pwd\nwhoami\n".utf8))

        XCTAssertEqual(launcher.sentInput.map { String(decoding: $0, as: UTF8.self) }, ["pwd\nwhoami\n"])
        XCTAssertEqual(submittedCommands, ["pwd", "whoami"])
    }

    func testLocalTerminalReportsCommandCompletionAfterOSC7DirectoryUpdate() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )
        var completedRuntimeIDs: [String] = []
        controller.onCommandFinished = { pane in
            completedRuntimeIDs.append(pane.runtimeID)
        }

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/tmp")

        XCTAssertEqual(completedRuntimeIDs, ["term_local"])
    }

    func testLocalTerminalShowsIDEStyleCompletionCandidateList() {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )

        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        controller.view.layoutSubtreeIfNeeded()
        controller.terminalView.dataReceived(slice: ArraySlice(Array("root@local:~# ".utf8)))
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("do".utf8))
        )
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("联想补全"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("2 条匹配"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("↵ Tab  docker"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("docker-compose"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("Enter 执行"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("Tab 填充"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("Esc 关闭"))
        XCTAssertEqual(controller.commandHintCompletionChoiceCountForTesting, 2)
        XCTAssertEqual(controller.commandHintSelectedCompletionIndexForTesting, 0)
        XCTAssertEqual(controller.commandHintPresentationKindForTesting, .completion)
        XCTAssertTrue(controller.commandHintUsesTerminalCompletionStyleForTesting)
        XCTAssertTrue(
            controller.terminalView.frame.intersects(controller.commandHintFrameForTesting),
            "Completion candidates should float over the terminal near the current prompt, not in the bottom command-hint area."
        )
        XCTAssertGreaterThanOrEqual(
            controller.commandHintFrameForTesting.minX,
            controller.terminalView.frame.minX + 24
        )
    }

    func testTerminalCommandCompletionSuggestsPathCandidatesFromProvider() throws {
        let provider = RecordingTerminalPathCompletionProvider(candidates: [
            TerminalPathCompletionCandidate(name: "app", isDirectory: true),
            TerminalPathCompletionCandidate(name: "api", isDirectory: true)
        ])

        let suggestion = try XCTUnwrap(TerminalCommandCompletionEngine.suggestion(
            for: "cd /srv/ap",
            pathCompletionProvider: provider
        ))

        XCTAssertEqual(provider.requests.map(\.parentPath), ["/srv"])
        XCTAssertEqual(provider.requests.map(\.namePrefix), ["ap"])
        XCTAssertEqual(suggestion.choices.map(\.replacement), ["/srv/app/", "/srv/api/"])
        XCTAssertEqual(suggestion.choices.map(\.kind), [.path, .path])
        XCTAssertEqual(suggestion.choices.first?.detail, "目录")
        XCTAssertEqual(suggestion.insertion, "p/")
        XCTAssertTrue(suggestion.visibleText.contains("cd /srv/app/"))
    }

    func testLocalTerminalCompletesCurrentDirectoryPathsWithTab() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioPathCompletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("app", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("archive", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: rootURL.path)
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("cd ap".utf8))
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("cd app/"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("目录"))
        XCTAssertEqual(controller.commandHintCompletionChoiceCountForTesting, 1)

        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([9]))

        XCTAssertEqual(
            launcher.sentInput.map { String(decoding: $0, as: UTF8.self) },
            ["p/"]
        )
    }

    func testLocalTerminalCompletionPopupFollowsLightTerminalTheme() {
        let suiteName = "StacioLightCompletionPopup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .light
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("do".utf8))
        )

        XCTAssertEqual(controller.commandHintPresentationKindForTesting, .completion)
        XCTAssertTrue(controller.commandHintUsesTerminalCompletionStyleForTesting)
        XCTAssertFalse(controller.commandHintCompletionUsesFixedDarkAppearanceForTesting)
        XCTAssertGreaterThanOrEqual(
            controller.commandHintCompletionBackgroundColorForTesting.stacioTestAlphaComponent,
            0.9
        )
        XCTAssertGreaterThan(
            controller.commandHintCompletionBackgroundColorForTesting.stacioTestRelativeLuminance,
            0.65
        )
        XCTAssertGreaterThan(
            controller.commandHintCompletionPrimaryTextColorForTesting.stacioTestContrastRatio(
                against: controller.commandHintCompletionBackgroundColorForTesting
            ),
            4.5
        )
    }

    func testLocalTerminalCompletionPopupUsesReadablePathHighlightInLightTheme() throws {
        let suiteName = "StacioLightCompletionPathContrast-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .light
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("cd /home/\n".utf8))
        )
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("cd /".utf8))
        )

        let commandField = try XCTUnwrap(controller.view.firstTextField(containing: "cd /home/"))
        let attributed = commandField.attributedStringValue
        let range = (attributed.string as NSString).range(of: "home/")
        XCTAssertNotEqual(range.location, NSNotFound)
        let highlightColor = try XCTUnwrap(
            attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        )
        let rowBackground = try XCTUnwrap(commandField.superview?.layer?.backgroundColor)

        XCTAssertGreaterThanOrEqual(
            highlightColor.stacioTestContrastRatio(against: NSColor(cgColor: rowBackground) ?? .white),
            4.5
        )
    }

    func testLocalTerminalSystemThemeReappliesWhenEffectiveAppearanceChanges() throws {
        let suiteName = "StacioLocalTerminalSystemAppearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .system
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.view.appearance = NSAppearance(named: .aqua)
        controller.view.viewDidChangeEffectiveAppearance()
        let lightBackground = try XCTUnwrap(controller.terminalView.layer?.backgroundColor)

        controller.view.appearance = NSAppearance(named: .darkAqua)
        controller.view.viewDidChangeEffectiveAppearance()
        let darkBackground = try XCTUnwrap(controller.terminalView.layer?.backgroundColor)

        XCTAssertGreaterThan(lightBackground.stacioTestRelativeLuminance, 0.75)
        XCTAssertLessThan(darkBackground.stacioTestRelativeLuminance, 0.25)
    }

    func testLocalTerminalCanNavigateAndAcceptCompletionCandidate() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("do".utf8))
        )
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([27, 91, 66]))

        XCTAssertEqual(controller.commandHintSelectedCompletionIndexForTesting, 1)
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("↵ Tab  docker-compose"))
        XCTAssertEqual(launcher.sentInput, [])

        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([9]))

        XCTAssertEqual(
            launcher.sentInput.map { String(decoding: $0, as: UTF8.self) },
            ["cker-compose "]
        )
        XCTAssertEqual(controller.commandHintVisibleTextForTesting, "")
    }

    func testLocalTerminalKeepsTypedInputWhenPressingEnterWithCompletionVisible() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("do".utf8))
        )
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([27, 91, 66]))
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([13]))

        XCTAssertEqual(launcher.sentInput, [])
        XCTAssertEqual(controller.commandHintVisibleTextForTesting, "")
    }

    func testLocalTerminalEnterDoesNotAcceptHistoryCompletionForCdRoot() {
        let observer = TerminalCommandInputObserver()
        let settings = AppSettings()

        let suggestion = observer.ingest(
            bytes: Array("cd /".utf8),
            settings: settings,
            historyCommands: ["cd /home/"]
        )

        XCTAssertTrue(suggestion.completionSuggestion?.visibleText.contains("cd /home/") == true)

        let enter = observer.ingest(
            bytes: [13],
            settings: settings,
            historyCommands: ["cd /home/"]
        )

        XCTAssertNil(enter.acceptedCompletionBytes)
        XCTAssertFalse(enter.shouldConsumeInput)
        XCTAssertEqual(enter.currentLine, "")
    }

    func testLocalTerminalCanCloseCompletionWithEscape() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("do".utf8))
        )
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([27]))

        XCTAssertEqual(controller.commandHintVisibleTextForTesting, "")
        XCTAssertEqual(launcher.sentInput, [])
    }

    func testLocalTerminalShowsHistoryCommandCompletionBeforeBuiltIns() {
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("docker compose ps\n".utf8))
        )
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("docker c".utf8))
        )

        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("历史记录"))
        XCTAssertTrue(controller.commandHintVisibleTextForTesting.contains("docker compose ps"))

        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([9]))

        XCTAssertEqual(
            launcher.sentInput.map { String(decoding: $0, as: UTF8.self) },
            ["ompose ps"]
        )
    }

    func testLocalTerminalCommandSuggestionCanBeDisabled() {
        let suiteName = "StacioCommandSuggestionDisabled-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalCommandSuggestionEnabled = false
        }
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            processLauncher: launcher,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("do".utf8))
        )
        controller.terminalView.send(source: controller.terminalView, data: ArraySlice([9]))

        XCTAssertEqual(controller.commandHintVisibleTextForTesting, "")
        XCTAssertEqual(launcher.sentInput, [])
    }

    func testTerminalCommandCompletionHonorsHistoryLengthAndWordSeparatorSettings() throws {
        let settings = AppSettings(
            terminalCommandSuggestionHistoryMinLength: 5,
            terminalCommandSuggestionHistoryMaxLength: 12,
            terminalCommandSuggestionWordSeparators: ":"
        )
        let historySuggestion = try XCTUnwrap(TerminalCommandCompletionEngine.suggestion(
            for: "git s",
            settings: settings,
            historyCommands: [
                "git",
                "git status",
                "git status --short"
            ]
        ))

        XCTAssertEqual(historySuggestion.replacement, "git status")
        XCTAssertEqual(historySuggestion.detail, "历史记录")

        let separatorSuggestion = try XCTUnwrap(TerminalCommandCompletionEngine.suggestion(
            for: "docker:co",
            settings: settings
        ))

        XCTAssertEqual(separatorSuggestion.replacement, "compose")
    }

    func testTerminalCommandCompletionCoversMainstreamLinuxTooling() {
        let examples: [(String, String)] = [
            ("apt ins", "install"),
            ("yum upd", "update"),
            ("dnf rem", "remove"),
            ("zypper in", "install"),
            ("pacman -S", "-Syu"),
            ("apk ad", "add"),
            ("systemctl rest", "restart"),
            ("docker comp", "compose"),
            ("kubectl get dep", "deployments")
        ]

        for (line, expectedReplacement) in examples {
            let suggestion = TerminalCommandCompletionEngine.suggestion(for: line)
            XCTAssertEqual(suggestion?.replacement, expectedReplacement, line)
            XCTAssertTrue(suggestion?.visibleText.contains("Linux") ?? false, line)
        }
    }

    func testTerminalCommandCompletionReturnsMultipleIDEStyleChoices() throws {
        let suggestion = try XCTUnwrap(TerminalCommandCompletionEngine.suggestion(for: "do"))

        XCTAssertEqual(suggestion.replacement, "docker")
        XCTAssertEqual(suggestion.choices.map(\.replacement), ["docker", "docker-compose"])
    }

    func testLocalTerminalDoesNotShowCommandHintWhenEnhancedHighlightingIsDisabled() {
        let suiteName = "StacioCommandHintDisabled-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .ansiOnly
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("docker compose up -d\n".utf8))
        )

        XCTAssertEqual(controller.commandHintVisibleTextForTesting, "")
    }

    func testCommandHintOverlayDoesNotInterceptTerminalMouseEvents() throws {
        let suiteName = "StacioCommandHintHitTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.send(
            source: controller.terminalView,
            data: ArraySlice(Array("docker compose up -d\n".utf8))
        )
        let overlay = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Terminal.commandHintOverlay")
        )
        overlay.frame = NSRect(x: 0, y: 0, width: 360, height: 48)

        XCTAssertNil(overlay.hitTest(NSPoint(x: 16, y: 16)))
    }

    func testTerminalPaneStartsShellWithRichColorEnvironment() {
        let sink = RecordingTerminalEventSink()
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            processLauncher: launcher,
            autoStartProcess: true
        )

        controller.loadView()
        controller.viewDidAppear()

        XCTAssertEqual(launcher.startedExecutable, "/bin/zsh")
        XCTAssertTrue(launcher.startedArgs?.contains("-l") == true)
        let environment = launcher.startedEnvironmentDictionary
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["COLORTERM"], "truecolor")
        XCTAssertEqual(environment["CLICOLOR"], "1")
        XCTAssertEqual(environment["CLICOLOR_FORCE"], "1")
        XCTAssertEqual(environment["FORCE_COLOR"], "1")
        XCTAssertEqual(environment["TERM_PROGRAM"], "Stacio")
        XCTAssertEqual(environment["SYSTEMD_COLORS"], "1")
        XCTAssertEqual(environment["SYSTEMD_PAGERSECURE"], "0")
        XCTAssertEqual(environment["GREP_COLORS"], TerminalHighlighting.richGrepColors)
        XCTAssertEqual(environment["GREP_COLOR"], "01;38;5;214")
        XCTAssertEqual(environment["LS_COLORS"], TerminalHighlighting.richLSColors)
        XCTAssertNotNil(environment["LSCOLORS"])
        XCTAssertNil(environment["NO_COLOR"])
    }

    func testLocalTerminalPassesConfiguredX11DisplayToShellEnvironment() {
        let suiteName = "StacioTerminalX11Display-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalX11Display = " :10 "
        }
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            processLauncher: launcher,
            autoStartProcess: true
        )

        controller.loadView()
        controller.viewDidAppear()

        XCTAssertEqual(launcher.startedEnvironmentDictionary["DISPLAY"], ":10")
    }

    func testTerminalHighlightingIncludesDockerFilePatterns() {
        let colors = TerminalHighlighting.richLSColors
        let colorTokens = Set(colors.split(separator: ":").map(String.init))

        XCTAssertTrue(colors.contains("Dockerfile=38;5;75"))
        XCTAssertTrue(colors.contains("*Dockerfile=38;5;75"))
        XCTAssertTrue(colorTokens.contains("dockerfile=38;5;75"))
        XCTAssertTrue(colors.contains("Containerfile=38;5;75"))
        XCTAssertTrue(colors.contains("*Containerfile=38;5;75"))
        XCTAssertTrue(colorTokens.contains("containerfile=38;5;75"))
        XCTAssertTrue(colors.contains(".dockerignore=38;5;244"))
        XCTAssertTrue(colors.contains("*.dockerignore=38;5;244"))
        XCTAssertTrue(colors.contains("docker-compose.yml=38;5;179"))
        XCTAssertTrue(colors.contains("*docker-compose.yml=38;5;179"))
        XCTAssertTrue(colors.contains("compose.yaml=38;5;179"))
        XCTAssertTrue(colors.contains("*compose.yaml=38;5;179"))
        XCTAssertTrue(colorTokens.contains("compose.dev.yml=38;5;179"))
        XCTAssertTrue(colorTokens.contains("compose.staging.yaml=38;5;179"))
        XCTAssertTrue(colors.contains("docker-bake.hcl=38;5;179"))
        XCTAssertTrue(colors.contains("*docker-bake*.hcl=38;5;179"))
        XCTAssertTrue(colors.contains("buildkitd.toml=38;5;179"))
        XCTAssertTrue(colorTokens.contains("daemon.json=38;5;179"))
        XCTAssertTrue(colorTokens.contains("containers.conf=38;5;179"))
        XCTAssertTrue(colorTokens.contains("registries.conf=38;5;179"))
        XCTAssertTrue(colors.contains("*.dockerfile=38;5;75"))
        XCTAssertTrue(colors.contains("*.oci=38;5;203"))
        XCTAssertTrue(colors.contains("*.tf=38;5;141"))
        XCTAssertTrue(colors.contains("*.tfvars=38;5;141"))
        XCTAssertTrue(colors.contains(".env.*=38;5;108"))
        XCTAssertTrue(colors.contains("*.service=38;5;110"))
        XCTAssertTrue(colors.contains("*.timer=38;5;110"))
        XCTAssertTrue(colors.contains("*.mount=38;5;110"))
        XCTAssertTrue(colors.contains("*.target=38;5;110"))
        XCTAssertTrue(colors.contains("nginx.conf=38;5;110"))
        XCTAssertTrue(colors.contains("*.kubeconfig=38;5;75"))
        XCTAssertTrue(colors.contains("Chart.yaml=38;5;179"))
        XCTAssertTrue(colors.contains("values.yaml=38;5;179"))
        XCTAssertTrue(colorTokens.contains("kustomization.yaml=38;5;179"))
        XCTAssertTrue(colorTokens.contains("kustomization.yml=38;5;179"))
        XCTAssertTrue(colorTokens.contains("sources.list=38;5;179"))
        XCTAssertTrue(colorTokens.contains("*.sources=38;5;179"))
        XCTAssertTrue(colors.contains("compose.override.yaml=38;5;179"))
        XCTAssertTrue(colors.contains("*compose.override*.yaml=38;5;179"))
        XCTAssertTrue(colors.contains("compose.prod.yml=38;5;179"))
        XCTAssertTrue(colors.contains("Jenkinsfile=38;5;214"))
        XCTAssertTrue(colors.contains("Vagrantfile=38;5;141"))
        XCTAssertTrue(colors.contains(".envrc=38;5;108"))
        XCTAssertTrue(colors.contains("*.repo=38;5;179"))
        XCTAssertTrue(colors.contains("*.log=38;5;244"))
        XCTAssertTrue(colors.contains("*.pem=38;5;221"))
        XCTAssertTrue(colors.contains("*.crt=38;5;221"))
        XCTAssertTrue(colors.contains("*.key=38;5;203"))
    }

    func testTerminalPaneDoesNotWriteCurrentDirectoryHookIntoVisibleTerminalInput() {
        let sink = RecordingTerminalEventSink()
        let launcher = RecordingLocalTerminalLauncher()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            processLauncher: launcher,
            autoStartProcess: true
        )

        controller.loadView()
        controller.viewDidAppear()

        let startupInput = launcher.sentInput
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
        XCTAssertFalse(startupInput.contains("__stacio_report_cwd"))
        XCTAssertFalse(startupInput.contains("PROMPT_COMMAND"))
        XCTAssertFalse(startupInput.contains("precmd_functions"))
    }

    func testResizeIsForwardedToEventSink() throws {
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            autoStartProcess: false
        )

        controller.loadView()
        controller.sizeChanged(source: controller.terminalView, newCols: 100, newRows: 32)

        XCTAssertEqual(sink.resizeEvents, [TerminalResizeEvent(runtimeID: "term_test", cols: 100, rows: 32)])
    }

    func testLocalTerminalCommandClickLinkRequestsBrowserOpen() {
        let opener = RecordingTerminalLinkOpener()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            linkOpener: opener,
            autoStartProcess: false
        )

        controller.loadView()
        controller.requestOpenLink(
            source: controller.terminalView,
            link: "https://example.com/runbook",
            params: [:]
        )

        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), ["https://example.com/runbook"])
    }

    func testLocalTerminalCommandClickNormalizesBareWebAndIPAddressLinks() {
        let opener = RecordingTerminalLinkOpener()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            linkOpener: opener,
            autoStartProcess: false
        )

        controller.loadView()
        [
            "192.168.8.10",
            "192.168.8.10:9090/status.",
            "www.stacio.example/docs)",
            "stacio.example/health"
        ].forEach { link in
            controller.requestOpenLink(
                source: controller.terminalView,
                link: link,
                params: [:]
            )
        }

        XCTAssertEqual(opener.openedURLs.map(\.absoluteString), [
            "http://192.168.8.10",
            "http://192.168.8.10:9090/status",
            "https://www.stacio.example/docs",
            "https://stacio.example/health"
        ])
    }

    func testLocalTerminalRichHighlightingStaysOnDisplayBranchOnly() {
        let suiteName = "StacioLocalRichHighlightSplit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalHighlightLevel = .commandLineEnhanced
            settings.terminalRichHighlightingEnabled = true
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = "tokyo-night"
        }
        let runtimeID = "term_local_split_\(UUID().uuidString)"
        var broadcastBytes: [[UInt8]] = []
        let subscription = TerminalOutputBroadcastHub.shared.subscribe(runtimeID: runtimeID) { event in
            if event.kind == .output {
                broadcastBytes.append(event.bytes)
            }
        }
        defer {
            TerminalOutputBroadcastHub.shared.unsubscribe(runtimeID: runtimeID, subscription: subscription)
        }
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: runtimeID,
            shellPath: "/bin/zsh",
            eventSink: sink,
            settingsStore: settingsStore,
            autoStartProcess: false
        )
        let raw = "ERROR status=1 192.168.8.10:8080 /var/log/app.log\n"

        controller.loadView()
        controller.terminalView.dataReceived(slice: ArraySlice(Array(raw.utf8)))

        XCTAssertEqual(controller.terminalOutputTranscript, raw)
        XCTAssertEqual(broadcastBytes, [Array(raw.utf8)])
        XCTAssertEqual(sink.outputBytes, [Array(raw.utf8)])
        XCTAssertFalse(controller.terminalOutputTranscript.contains("\u{001B}["))
        XCTAssertFalse(controller.terminalOutputTranscript.contains("\u{001B}]8;;"))
    }

    func testInvalidLocalTerminalResizeIsIgnored() {
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            autoStartProcess: false
        )

        controller.loadView()
        let resizeEventsBeforeInvalidResize = sink.resizeEvents
        controller.sizeChanged(source: controller.terminalView, newCols: -2, newRows: 3)
        controller.sizeChanged(source: controller.terminalView, newCols: 100, newRows: 0)

        XCTAssertEqual(sink.resizeEvents, resizeEventsBeforeInvalidResize)
    }

    func testCoreTerminalEventSinkIgnoresInvalidResizeBeforeUnsignedConversion() {
        let sink = CoreBridgeTerminalEventSink()

        XCTAssertNoThrow(try sink.terminalDidResize(runtimeID: "missing-runtime", cols: -2, rows: 3))
        XCTAssertNoThrow(try sink.terminalDidResize(runtimeID: "missing-runtime", cols: 100, rows: 0))
    }

    func testLocalTerminalControlScrollZoomsSharedFontSizeAndRelayoutsTerminal() {
        let suiteName = "StacioLocalTerminalZoom-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.performControlScrollZoomForTesting(deltaY: -5)

        XCTAssertEqual(settingsStore.snapshot().terminalFontSize, 14)
        XCTAssertEqual(controller.terminalView.font.pointSize, 14, accuracy: 0.1)
        XCTAssertTrue(controller.terminalView.needsLayout)
    }

    func testLocalTerminalSystemThemeRefreshesNativeColorsWhenEffectiveAppearanceChanges() {
        let suiteName = "StacioLocalTerminalSystemAppearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .system
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.nativeForegroundColor = .systemRed
        controller.terminalView.nativeBackgroundColor = .systemBlue
        controller.terminalView.caretColor = .systemGreen
        controller.terminalView.selectedTextBackgroundColor = .systemYellow
        controller.view.viewDidChangeEffectiveAppearance()

        assertTerminalUsesSystemAdaptiveColors(controller.terminalView)
    }

    func testTerminalPaneTracksHostCurrentDirectoryUpdates() {
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            autoStartProcess: false
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "/Users/mac/project")
        controller.hostCurrentDirectoryUpdate(source: controller.terminalView, directory: "   ")

        XCTAssertEqual(controller.currentLocalDirectory, "/Users/mac/project")
    }

    func testTerminalPaneNormalizesOSC7FileURLCurrentDirectoryUpdates() {
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            autoStartProcess: false
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(
            source: controller.terminalView,
            directory: "file:///localhost/Users/mac/Stacio%20Project"
        )

        XCTAssertEqual(controller.currentLocalDirectory, "/Users/mac/Stacio Project")
    }

    func testTerminalPaneNormalizesUnescapedOSC7FileURLCurrentDirectoryUpdates() {
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            autoStartProcess: false
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(
            source: controller.terminalView,
            directory: "file://localhost/Users/mac/Stacio Project"
        )

        XCTAssertEqual(controller.currentLocalDirectory, "/Users/mac/Stacio Project")
    }

    func testTerminalPanePreservesOSC7PathCharactersThatHaveURLMeaning() {
        let sink = RecordingTerminalEventSink()
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            autoStartProcess: false
        )

        controller.loadView()
        controller.hostCurrentDirectoryUpdate(
            source: controller.terminalView,
            directory: "file://localhost/Users/mac/build#1?draft"
        )

        XCTAssertEqual(controller.currentLocalDirectory, "/Users/mac/build#1?draft")
    }


    func testTerminalPaneRetainsEventSinkForLifecycleEvents() {
        var retainedOnlyByController: RecordingTerminalEventSink? = RecordingTerminalEventSink()
        let releasedWithoutControllerRetention = WeakReference(retainedOnlyByController)
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: retainedOnlyByController!,
            autoStartProcess: false
        )
        retainedOnlyByController = nil

        controller.loadView()
        controller.sizeChanged(source: controller.terminalView, newCols: 90, newRows: 28)

        XCTAssertNotNil(releasedWithoutControllerRetention.value)
        XCTAssertEqual(releasedWithoutControllerRetention.value?.resizeEvents, [
            TerminalResizeEvent(runtimeID: "term_test", cols: 90, rows: 28)
        ])
    }

    func testTerminalPaneSupportsFindCopyPasteAndCloseCommands() {
        let sink = RecordingTerminalEventSink()
        let suiteName = "StacioTerminalPaste-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalMultiLinePasteConfirmationEnabled = false
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: sink,
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.terminalView.feed(text: "alpha beta gamma\r\n")
        NSPasteboard.general.clearContents()

        XCTAssertTrue(controller.find("beta"))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")

        controller.copySelection()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "beta")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pwd\n", forType: .string)
        controller.pasteClipboard()
        controller.closeTerminal()

        XCTAssertEqual(sink.closedRuntimeIDs, ["term_test"])
    }

    func testTerminalPastePreparationConfirmsMultiLineInput() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StacioTerminalPaste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("pwd\nwhoami\n", forType: .string)
        var prompted = false

        let blocked = TerminalPastePreparation.preparedPasteString(
            settings: AppSettings(terminalMultiLinePasteConfirmationEnabled: true),
            pasteboard: pasteboard
        ) { value in
            prompted = value == "pwd\nwhoami\n"
            return false
        }

        XCTAssertNil(blocked)
        XCTAssertTrue(prompted)
        XCTAssertEqual(
            TerminalPastePreparation.preparedPasteString(
                settings: AppSettings(terminalMultiLinePasteConfirmationEnabled: false),
                pasteboard: pasteboard
            ) { _ in
                XCTFail("Disabled confirmation should not prompt")
                return false
            },
            "pwd\nwhoami\n"
        )
    }

    func testTerminalPastePreparationUsesFileURLWhenImagePathPasteIsEnabled() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("StacioTerminalImagePaste-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/stacio-image.png") as NSURL])

        XCTAssertEqual(
            TerminalPastePreparation.preparedPasteString(
                settings: AppSettings(terminalPasteImageAsPathEnabled: true),
                pasteboard: pasteboard
            ),
            "/tmp/stacio-image.png"
        )
    }

    func testLocalTerminalAppliesLineNumberAndTimestampGutterSettings() {
        let suiteName = "StacioTerminalGutter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalLineNumbersEnabled = true
            settings.terminalTimestampsEnabled = true
            settings.terminalTimestampMillisecondsEnabled = true
            settings.terminalWorkspacePaddingEnabled = true
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_test",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.view.setFrameSize(NSSize(width: 900, height: 520))
        controller.terminalView.setFrameSize(NSSize(width: 740, height: 420))
        XCTAssertEqual(controller.lineInfoGutterVisibleTextForTesting, "")
        controller.terminalView.dataReceived(slice: ArraySlice(Array("alpha\r\nbravo\r\nomega".utf8)))

        XCTAssertTrue(controller.lineInfoGutterVisibleTextForTesting.contains("["))
        XCTAssertTrue(controller.lineInfoGutterVisibleTextForTesting.contains("  1"))
        XCTAssertTrue(controller.lineInfoGutterVisibleTextForTesting.contains("  3"))
        XCTAssertFalse(controller.lineInfoGutterVisibleTextForTesting.contains(" 24"))
        XCTAssertTrue(controller.lineInfoGutterVisibleTextForTesting.contains("."))
        XCTAssertTrue(controller.lineInfoGutterUsesTerminalSurfaceStyleForTesting)
        XCTAssertEqual(controller.lineInfoGutterFontPointSizeForTesting, CGFloat(settingsStore.snapshot().terminalFontSize))
        XCTAssertEqual(controller.lineInfoGutterLabelCountForTesting, 3)
        XCTAssertEqual(controller.lineInfoGutterRowHeightForTesting, controller.terminalView.caretFrame.size.height, accuracy: 0.1)
        XCTAssertGreaterThan(controller.lineInfoGutterPreferredWidthForTesting, 140)
        XCTAssertLessThan(controller.lineInfoGutterPreferredWidthForTesting, 180)
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.lineInfoGutter"))
    }

    func testLocalTerminalLineInfoGutterSystemThemeResolvesReadableTextInDarkAppearance() throws {
        let suiteName = "StacioTerminalGutterDark-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.update { settings in
            settings.terminalTheme = .system
            settings.terminalLineNumbersEnabled = true
            settings.terminalTimestampsEnabled = true
        }
        let controller = TerminalPaneViewController(
            runtimeID: "term_gutter_dark",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            settingsStore: settingsStore,
            autoStartProcess: false
        )

        controller.loadView()
        controller.view.appearance = NSAppearance(named: .darkAqua)
        controller.terminalView.appearance = NSAppearance(named: .darkAqua)
        controller.view.setFrameSize(NSSize(width: 900, height: 520))
        controller.terminalView.setFrameSize(NSSize(width: 740, height: 420))
        controller.terminalView.dataReceived(slice: ArraySlice(Array("alpha\r\nbravo".utf8)))

        let color = try XCTUnwrap(controller.lineInfoGutterColorForTesting?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.45)
        XCTAssertGreaterThan(color.greenComponent, 0.45)
        XCTAssertGreaterThan(color.blueComponent, 0.45)
    }

    func testTerminalSearchBarShowsCountsNavigatesAndEscRestoresFocus() throws {
        let controller = TerminalPaneViewController(
            runtimeID: "term_search",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        controller.view.layoutSubtreeIfNeeded()
        controller.terminalView.feed(text: "alpha beta\r\nBETA beta\r\n")

        let window = NSWindow(contentViewController: controller)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.terminalView)

        XCTAssertFalse(controller.terminalSearchBarVisibleForTesting)

        controller.showFind()
        XCTAssertTrue(controller.terminalSearchBarVisibleForTesting)
        let searchBar = try XCTUnwrap(
            controller.view.firstSubview(withIdentifier: "Stacio.Terminal.searchBar") as? TerminalSearchBarView
        )
        XCTAssertNotNil(controller.view.firstSubview(withIdentifier: "Stacio.Terminal.searchField"))

        controller.setTerminalSearchQueryForTesting("beta")

        XCTAssertEqual(controller.terminalSearchSummaryForTesting, "第 1 / 共 3 个")
        XCTAssertEqual(controller.terminalSearchVisibleHighlightCountForTesting, 3)
        XCTAssertEqual(controller.terminalView.getSelection()?.lowercased(), "beta")

        controller.selectNextTerminalSearchMatchForTesting()
        XCTAssertEqual(controller.terminalSearchSummaryForTesting, "第 2 / 共 3 个")
        XCTAssertEqual(controller.terminalView.getSelection()?.lowercased(), "beta")

        controller.selectPreviousTerminalSearchMatchForTesting()
        XCTAssertEqual(controller.terminalSearchSummaryForTesting, "第 1 / 共 3 个")

        XCTAssertTrue(searchBar.control(
            NSSearchField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))

        XCTAssertFalse(controller.terminalSearchBarVisibleForTesting)
        XCTAssertFalse(controller.terminalView.selectionActive)
        XCTAssertIdentical(window.firstResponder as AnyObject?, controller.terminalView)
    }

    func testTerminalSearchBarPromotesAboveWorkspaceDashboardOverlay() throws {
        let controller = TerminalPaneViewController(
            runtimeID: "term_local",
            shellPath: "/bin/zsh",
            eventSink: RecordingTerminalEventSink(),
            autoStartProcess: false
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        controller.view.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let root = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 500))
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        root.addSubview(controller.view)

        let dashboardOverlay = NSView(frame: NSRect(x: 500, y: 250, width: 280, height: 220))
        dashboardOverlay.setAccessibilityIdentifier("Stacio.Metrics.dashboard.test")
        root.addSubview(dashboardOverlay, positioned: .above, relativeTo: controller.view)

        window.makeKeyAndOrderFront(nil)
        controller.showFind()

        let searchBar = try XCTUnwrap(
            root.firstSubview(withIdentifier: "Stacio.Terminal.searchBar") as? TerminalSearchBarView
        )
        XCTAssertTrue(searchBar.superview === root)
        XCTAssertTrue(root.subviews.last === searchBar)
        XCTAssertTrue(root.subviews.contains(dashboardOverlay))

        controller.closeTerminalSearchWithEscapeForTesting()

        XCTAssertTrue(root.subviews.contains(dashboardOverlay))
        XCTAssertFalse(dashboardOverlay.isHidden)
    }
}

private final class RecordingLocalTerminalLauncher: LocalTerminalProcessLaunching {
    private(set) var startedExecutable: String?
    private(set) var startedArgs: [String]?
    private(set) var startedEnvironment: [String]?
    private(set) var sentInput: [[UInt8]] = []
    private(set) var terminated = false
    var running = false

    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        startedExecutable = executable
        startedArgs = args
        startedEnvironment = environment
        running = true
    }

    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool {
        running
    }

    func terminate(_ terminalView: LocalProcessTerminalView) {
        terminated = true
        running = false
    }

    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {
        sentInput.append(bytes)
    }

    var startedEnvironmentDictionary: [String: String] {
        Dictionary(uniqueKeysWithValues: (startedEnvironment ?? []).compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0], parts[1])
        })
    }
}

private final class RecordingTerminalEventSink: TerminalEventSink {
    private(set) var resizeEvents: [TerminalResizeEvent] = []
    private(set) var closedRuntimeIDs: [String] = []
    private(set) var outputRuntimeIDs: [String] = []
    private(set) var outputBytes: [[UInt8]] = []

    func terminalDidResize(runtimeID: String, cols: Int, rows: Int) throws {
        resizeEvents.append(TerminalResizeEvent(runtimeID: runtimeID, cols: cols, rows: rows))
    }

    func terminalDidProduceOutput(runtimeID: String, bytes: [UInt8]) throws {
        outputRuntimeIDs.append(runtimeID)
        outputBytes.append(bytes)
    }

    func terminalDidReceiveInput(runtimeID: String, bytes: [UInt8]) throws {}

    func terminalDidClose(runtimeID: String) throws {
        closedRuntimeIDs.append(runtimeID)
    }
}

private final class WeakReference<T: AnyObject> {
    weak var value: T?

    init(_ value: T?) {
        self.value = value
    }
}

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

    func firstTextField(containing text: String) -> NSTextField? {
        if let textField = self as? NSTextField,
           textField.attributedStringValue.string.contains(text) {
            return textField
        }
        for subview in subviews {
            if let match = subview.firstTextField(containing: text) {
                return match
            }
        }
        return nil
    }
}

private func assertTerminalUsesSystemAdaptiveColors(
    _ terminalView: TerminalView,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(
        terminalView.nativeForegroundColor,
        StacioDesignSystem.resolvedColor(.textColor, for: terminalView),
        file: file,
        line: line
    )
    XCTAssertEqual(
        terminalView.nativeBackgroundColor,
        StacioDesignSystem.resolvedColor(.textBackgroundColor, for: terminalView),
        file: file,
        line: line
    )
    XCTAssertEqual(
        terminalView.caretColor,
        StacioDesignSystem.resolvedColor(.textColor, for: terminalView),
        file: file,
        line: line
    )
    XCTAssertEqual(
        terminalView.selectedTextBackgroundColor,
        StacioDesignSystem.resolvedColor(.selectedTextBackgroundColor, for: terminalView),
        file: file,
        line: line
    )
}

func assertShellAcceptsScript(
    executable: String,
    arguments: [String],
    script: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output

    try process.run()
    input.fileHandleForWriting.write(Data(script.utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        let diagnostics = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTFail("\(executable) rejected OSC7 bootstrap: \(diagnostics)", file: file, line: line)
    }
}

func assertShellAcceptsScriptIfPresent(
    executable: String,
    arguments: [String],
    script: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        return
    }
    try assertShellAcceptsScript(
        executable: executable,
        arguments: arguments,
        script: script,
        file: file,
        line: line
    )
}
