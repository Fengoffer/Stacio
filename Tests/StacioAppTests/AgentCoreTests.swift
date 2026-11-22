import XCTest
import StacioAgentBridge
@testable import StacioApp

@MainActor
final class AgentCoreTests: XCTestCase {
 func testProtocolFrameSplitAcrossEveryCharacterNeverReachesProse() {
 for marker in ["<｜DSML｜calls>", "<||DSML||invoke>", "<|DSML|calls>"] {
 var stream = AgentVisibleResponse()
 var visible = ""
 for character in "CPU < 8。" + marker + "execute_terminal_command" {
 visible += stream.append(String(character))
 }
 visible += stream.finish()
 XCTAssertEqual(visible, "CPU < 8。")
 XCTAssertTrue(stream.sawProtocol)
 }
 }

 func testReasoningStaysVisibleAcrossToolStepsAndFoldsAtTurnEnd() throws {
 let row = AgentAssistantMessageView(onCopy: nil)
 var item = AgentItem(kind: .assistant, reasoning: "采样说明", isStreaming: true)
 row.setReasoningTurnActive(true)
 row.update(item: item, width: 460)
 let column = try XCTUnwrap(row.subviews.compactMap { $0 as? NSStackView }.first)
 let scroll = try XCTUnwrap(column.arrangedSubviews.compactMap { $0 as? NSScrollView }.first)
 let toggle = try XCTUnwrap(column.arrangedSubviews.compactMap { $0 as? NSButton }.first)
 XCTAssertFalse(scroll.isHidden)
 XCTAssertLessThan(try XCTUnwrap(scroll.constraints.first { $0.firstAttribute == .height }).constant, 50)
 item.isStreaming = false
 row.update(item: item, width: 460)
 XCTAssertFalse(scroll.isHidden)
 toggle.performClick(nil)
 toggle.performClick(nil)
 row.setReasoningTurnActive(false)
 row.update(item: item, width: 460)
 XCTAssertTrue(scroll.isHidden)
 toggle.performClick(nil)
 XCTAssertFalse(scroll.isHidden)
 }

 func testPhaseCaptionsMatchReference() {
 XCTAssertEqual(AgentPhase.modelRequesting.caption, "等待模型响应")
 XCTAssertEqual(AgentPhase.thinking.caption, "深度思考中...")
 XCTAssertEqual(AgentPhase.waitingApproval.caption, "等待执行确认")
 XCTAssertEqual(AgentPhase.toolExecuting.caption, "正在执行工具")
 XCTAssertEqual(AgentPhase.completed.caption, "任务已完成")
 XCTAssertEqual(AgentPhase.interrupted.caption, "任务已中断")
 }

 func testActivePhaseSet() {
 XCTAssertTrue(AgentPhase.toolExecuting.isActive)
 XCTAssertFalse(AgentPhase.completed.isActive)
 XCTAssertFalse(AgentPhase.interrupted.isActive)
 }

 func testPromptEnhancementReplacesDraftAndCanBeUndoneOrRepeated() async throws {
 let suite = "StacioPromptEnhancement.\(UUID())"
 let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
 defer { defaults.removePersistentDomain(forName: suite) }
 let settings = AppSettingsStore(defaults: defaults)
 let id = UUID()
 let models = ["chat-model", "deepseek-chat"].map {
 AIProviderModelConfiguration(id: $0, isEnabled: true, isManual: true, wasReturnedByLatestCatalog: false)
 }
 let provider = AIProviderConfiguration(id: id, profile: .openAICompatible, displayName: "Test",
 baseURL: "https://example.test/v1", models: models, defaultModelID: "chat-model",
 compatibilityProtocol: .chatCompletions, maxRetryCount: 0, requestTimeoutSeconds: 30,
 userAgent: "Stacio", isEnabled: true, lastVerifiedAt: nil, lastModelSyncAt: nil)
 try settings.saveAIProviderSettings(.init(aiProviders: [provider], defaultAIProviderID: id))
 XCTAssertEqual(AgentProviderResolver(settingsStore: settings).modelChoices().map { $0.modelID }, ["chat-model", "deepseek-chat"])
 let configuration = URLSessionConfiguration.ephemeral
 configuration.protocolClasses = [PromptEnhancementURLProtocol.self]
 let client = URLSession(configuration: configuration)
 defer { client.invalidateAndCancel() }
 let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 defer { try? FileManager.default.removeItem(at: directory) }
 let session = AgentSession(store: AgentStore(rootDirectory: directory, saveDebounce: 0),
 providerResolver: AgentProviderResolver(settingsStore: settings, keyStore: PromptEnhancementKeyStore()),
 promptEnhancer: AgentPromptEnhancer(session: client), executorResolver: PerTerminalInertResolver())

 func waitForCompletion() async throws {
 for _ in 0..<100 where session.enhancementState == .loading {
 try await Task.sleep(for: .milliseconds(20))
 }
 }
 session.updateDraft("  检查磁盘  ")
 session.enhanceDraft()
 XCTAssertEqual(session.enhancementState, .loading)
 try await waitForCompletion()
 XCTAssertEqual(session.enhancementState, .undo)
 XCTAssertEqual(session.active.draftText, "检查磁盘使用情况")
 XCTAssertTrue(session.active.items.isEmpty)
 session.enhanceDraft()
 XCTAssertEqual(session.active.draftText, "  检查磁盘  ")
 XCTAssertEqual(session.enhancementState, .idle)

 session.enhanceDraft()
 try await waitForCompletion()
 session.updateDraft("检查磁盘使用情况，统计目录大小")
 XCTAssertEqual(session.enhancementState, .idle)
 let cancellationStarted = expectation(description: "enhancement request started before cancellation")
 let cancellationStopped = expectation(description: "enhancement request cancelled before client teardown")
 PromptEnhancementURLProtocol.setCancellationExpectations(started: cancellationStarted, stopped: cancellationStopped)
 defer { PromptEnhancementURLProtocol.setCancellationExpectations(started: nil, stopped: nil) }
 session.enhanceDraft()
 XCTAssertEqual(session.enhancementState, .loading)
 await fulfillment(of: [cancellationStarted], timeout: 5)
 session.enhanceDraft()
 XCTAssertEqual(session.enhancementState, .idle)
 XCTAssertEqual(session.active.draftText, "检查磁盘使用情况，统计目录大小")
 await fulfillment(of: [cancellationStopped], timeout: 5)
 }

 func testPermissionModeContract() {
 XCTAssertEqual(AgentPermissionMode.allCases.count,3)
 XCTAssertEqual(AgentPermissionMode.allCases.map(\.label), [AgentConfirmationPolicyPreference.requireEveryCommand, .allowLowRiskWithoutPrompt, .allowAllWithoutPrompt].map(\.displayName))
 XCTAssertEqual(AgentPermissionMode.supervised.label, "请求批准")
 XCTAssertEqual(AgentPermissionMode.dangerFullAccess.label, "完全权限")
 XCTAssertTrue(AgentPermissionMode.dangerFullAccess.isDangerous)
 }

 func testGlobalApprovalConstraintsStillApplyToConversationPermissions() {
     let invocation = AgentToolInvocation(id: "constraints", name: AgentToolCatalog.terminalCommand,
         title: "执行命令", argumentsJSON: "{}", command: "touch ./result.txt")
     for policy in [AgentConfirmationPolicyPreference.requireEveryCommand, .allowReadOnlyWithoutPrompt] {
         let preferences = AppSettings(agentConfirmationPolicy: policy)
         guard case .ask = AgentPermissionPolicy.decide(invocation: invocation, mode: .dangerFullAccess, preferences: preferences) else {
             return XCTFail("全局限制不能被完全权限绕过")
         }
     }
     let disabled = AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt, aiAutoRunProposedCommands: false)
     guard case .ask = AgentPermissionPolicy.decide(invocation: invocation, mode: .dangerFullAccess, preferences: disabled) else {
         return XCTFail("关闭自动执行必须继续询问")
     }
     let unrestricted = AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt)
     guard case .ask = AgentPermissionPolicy.decide(invocation: invocation, mode: .smartApproval, preferences: unrestricted),
           case .allow = AgentPermissionPolicy.decide(invocation: invocation, mode: .dangerFullAccess, preferences: unrestricted) else {
         return XCTFail("全局完全权限不能替换当前对话权限")
     }
     let denied = AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt, agentCommandDenyPatterns: "touch")
     guard case .deny = AgentPermissionPolicy.decide(invocation: invocation, mode: .dangerFullAccess, preferences: denied) else {
         return XCTFail("禁止模式必须继续优先生效")
     }
 }

 func testPermissionMenuExplainsGlobalScopeAndOpensItsSettings() throws {
     let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
     defer { try? FileManager.default.removeItem(at: root) }
     let session = AgentSession(store: AgentStore(rootDirectory: root, saveDebounce: 0), executorResolver: PerTerminalInertResolver())
     session.setPermissionMode(.dangerFullAccess)
     let panel = AgentPanelViewController(session: session)
     var opened = false
     panel.onRequestPermissionSettings = { opened = true }
     let menu = panel.makePermissionMenu(preferences: AppSettings(agentConfirmationPolicy: .requireEveryCommand))
     let choices = menu.items.filter { $0.representedObject is String }
     XCTAssertEqual(choices.map(\.title), AgentPermissionMode.allCases.map(\.label))
     XCTAssertEqual(choices.first(where: { $0.state == .on })?.title, "完全权限")
     XCTAssertEqual(menu.items.first?.title, "当前对话权限")
     XCTAssertNotNil(menu.items.first(where: { $0.title == "全局审批策略：请求批准" }))
     XCTAssertNotNil(menu.items.first(where: { $0.title.contains("包括完全权限对话") }))
     let entry = try XCTUnwrap(menu.items.last)
     XCTAssertEqual(entry.title, L10n.Settings.openAIExecutionPermissions)
     XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(entry.action), to: entry.target, from: entry))
     XCTAssertTrue(opened)
     XCTAssertEqual(session.active.permissionMode, .dangerFullAccess)
 }

 func testPermissionTooltipKeepsGlobalConstraintAfterRunningStateRefresh() throws {
     let composer = AgentComposerView(frame: .zero)
     composer.apply(model: nil, permission: .dangerFullAccess, preferences: AppSettings(agentConfirmationPolicy: .requireEveryCommand))
     func findButton(_ view: NSView) -> NSButton? {
         if view.accessibilityIdentifier() == "Stacio.Agent.permission" { return view as? NSButton }
         return view.subviews.lazy.compactMap { findButton($0) }.first
     }
     let button = try XCTUnwrap(findButton(composer))
     composer.applyRunning(true)
     XCTAssertFalse(button.isEnabled)
     XCTAssertTrue(button.toolTip?.contains("包括完全权限对话") == true)
     composer.applyRunning(false)
     XCTAssertTrue(button.isEnabled)
     XCTAssertTrue(button.toolTip?.contains("当前对话权限：完全权限") == true)
     XCTAssertTrue(button.toolTip?.contains("包括完全权限对话") == true)
 }

 func testBackgroundSettingsNotificationRefreshesPermissionControlsOnMainThread() async throws {
     let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
     defer { try? FileManager.default.removeItem(at: root) }
     let session = AgentSession(store: AgentStore(rootDirectory: root, saveDebounce: 0), executorResolver: PerTerminalInertResolver())
     session.setPermissionMode(.dangerFullAccess)
     let panel = AgentPanelViewController(session: session)
     func findButton(_ view: NSView) -> NSButton? {
         if view.accessibilityIdentifier() == "Stacio.Agent.permission" { return view as? NSButton }
         return view.subviews.lazy.compactMap { findButton($0) }.first
     }
     let button = try XCTUnwrap(findButton(panel.view))
     button.title = "等待设置刷新"
     let refreshed = expectation(description: "permission control refreshed on main thread")
     let posted = expectation(description: "background settings notification returned")
     let observation = button.observe(\.title, options: [.new]) { _, change in
         guard change.newValue == "完全权限" else { return }
         XCTAssertTrue(Thread.isMainThread, "后台配置保存不能在后台更新 AppKit")
         refreshed.fulfill()
     }
     defer { observation.invalidate() }
     DispatchQueue(label: "stacio.tests.provider-persistence").async {
         NotificationCenter.default.post(name: AppSettingsStore.didChangeNotification, object: AppSettingsStore.shared)
         posted.fulfill()
     }
     await fulfillment(of: [posted, refreshed], timeout: 5)
     XCTAssertEqual(button.title, "完全权限")
     XCTAssertTrue(button.toolTip?.contains(AgentPermissionPolicy.globalConstraintDescription(preferences: session.permissionPreferences)) == true)
     XCTAssertTrue(button.isEnabled)
     withExtendedLifetime(panel) {}
 }

 func testQueuedSettingsNotificationDoesNotRetainClosedPanel() async throws {
     let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
     defer { try? FileManager.default.removeItem(at: root) }
     let session = AgentSession(store: AgentStore(rootDirectory: root, saveDebounce: 0), executorResolver: PerTerminalInertResolver())
     var panel: AgentPanelViewController? = AgentPanelViewController(session: session)
     weak var releasedPanel = panel
     _ = panel?.view
     // The main actor cannot run the enqueued refresh until this method yields.
     NotificationCenter.default.post(name: AppSettingsStore.didChangeNotification, object: AppSettingsStore.shared)
     panel = nil
     XCTAssertNil(releasedPanel, "排队的设置刷新不得延长已关闭面板的生命周期")
     await Task.yield()
     XCTAssertNil(releasedPanel)
     NotificationCenter.default.post(name: AppSettingsStore.didChangeNotification, object: AppSettingsStore.shared)
 }

 func testOutputCleanupRemovesEchoAndANSI() {
 let cleaned =  AgentTerminalExecutor.clean("ls -la\r\n\u{1B}[31mred\u{1B}[0m\r\nresult line\r\n", command: "ls -la")
 XCTAssertEqual(cleaned, "red\nresult line")
 }

 func testReadOnlyClassification() {
 XCTAssertTrue(AgentPermissionPolicy.isReadOnly(command: "ls -la"))
 XCTAssertTrue(AgentPermissionPolicy.isReadOnly(command: "cat /var/log/syslog | grep error"))
 XCTAssertTrue(AgentPermissionPolicy.isReadOnly(command: "df -h"))
 XCTAssertFalse(AgentPermissionPolicy.isReadOnly(command: "rm -rf /tmp/x"))
 XCTAssertFalse(AgentPermissionPolicy.isReadOnly(command: "echo hi > /tmp/out"))
 XCTAssertFalse(AgentPermissionPolicy.isReadOnly(command: "systemctl restart nginx"))
 }

 func testSupervisedModeAsksForWrites() {
 let invocation =  AgentToolInvocation(
 id: "c1",
 name: AgentToolCatalog.terminalCommand,
 title: "执行命令",
 argumentsJSON: "{}",
 command: "rm -rf /tmp/build"
 )
 let decision =  AgentPermissionPolicy.decide(
 invocation: invocation,
 mode: .supervised
 )
 guard case .ask(let request) =  decision else {
 XCTFail("expected ask")
 return
 }
 XCTAssertTrue(request.isDangerous)
 }

 func testDangerModeAllowsOrdinaryWrite() {
 let invocation =  AgentToolInvocation(
 id: "c2",
 name: AgentToolCatalog.terminalCommand,
 title: "执行命令",
 argumentsJSON: "{}",
 command: "touch /tmp/a"
 )
 if case .allow =  AgentPermissionPolicy.decide(invocation: invocation, mode: .dangerFullAccess) {
 } else {
 XCTFail("danger mode must allow ordinary writes")
 }
 }

 func testHardRuleAlwaysAsksEvenInDangerMode() {
 let invocation =  AgentToolInvocation(
 id: "c3",
 name: AgentToolCatalog.terminalCommand,
 title: "执行命令",
 argumentsJSON: "{}",
 command: "rm -rf /"
 )
 guard case .ask(let request) =  AgentPermissionPolicy.decide(invocation: invocation, mode: .dangerFullAccess) else {
 XCTFail("platform hard rules must still ask")
 return
 }
 XCTAssertTrue(request.isDangerous)
 }

 func testPermissionModesUseRiskAndTerminalPolicy() {
 func decision(_ command: String, _ mode: AgentPermissionMode, _ policy: SessionAutomationPolicy = .default) -> AgentPermissionPolicy.Decision {
 AgentPermissionPolicy.decide(
 invocation: AgentToolInvocation(id: "policy", name: AgentToolCatalog.terminalCommand, title: "执行命令", argumentsJSON: "{}", command: command),
 mode: mode, automation: policy)
 }
 guard case .ask = decision("pwd", .supervised),
 case .allow = decision("pwd", .smartApproval),
 case .allow = decision("mkdir -p /tmp/stacio-test", .smartApproval),
 case .ask = decision("touch ./result.txt", .smartApproval),
 case .allow = decision("touch ./result.txt", .dangerFullAccess),
 case .allow = decision("systemctl reload nginx.service", .dangerFullAccess),
 case .ask = decision("systemctl reload nginx.service", .smartApproval),
 case .allow = decision("systemctl reload nginx.service", .dangerFullAccess, .init(environment: "staging")),
 case .ask = decision("touch ./result.txt", .dangerFullAccess, .init(environment: "production")),
 case .ask = decision("pwd", .dangerFullAccess, .init(aiExecutionPolicy: "requireEveryCommand")),
 case .deny = decision("pwd", .dangerFullAccess, .init(aiExecutionPolicy: "disabled")) else {
 return XCTFail("审批档位及目标终端策略必须共同决定是否放行")
 }
 for command in ["docker version", "docker ps -a", "journalctl --unit=nginx --no-pager -n 50", "journalctl --no-pager -n 50 -u nginx", "journalctl -u nginx --lines=1000 --no-pager", "ss -tunlp", "sw_vers", "git status", "sudo apt-get update", "apt install -y docker.io", "sudo apt-get --assume-yes install curl", "systemctl restart docker"] {
 guard case .allow = decision(command, .dangerFullAccess),
       case .ask = decision(command, .smartApproval),
       case .ask = decision(command, .dangerFullAccess, .init(environment: "production")) else {
 return XCTFail("完全权限专项规则或会话限制未生效：\(command)")
 }
 }
 for command in ["systemctl start reboot.target", "sudo systemctl start systemd-poweroff.service", "systemctl restart nginx.service poweroff.target", "apt install docker.io", "apt install -y docker.io-", "journalctl -u nginx", "journalctl -u nginx --no-pager", "journalctl --unit= --no-pager -n 10", "journalctl -u nginx --unit=app --no-pager -n 10", "journalctl -u nginx --no-pager -f", "journalctl --no-pager -u nginx -n 1001", "journalctl -u nginx --no-pager -n all", "apt install -y ./local.deb", "systemctl restart --all", "docker rm api", "unknown-program"] {
 guard case .ask = decision(command, .dangerFullAccess) else { return XCTFail("需要审批：\(command)") }
 }
 for command in ["sort -ro /tmp/output /tmp/input", "find . -delete", "echo ok; touch /tmp/file", "pwd\nwhoami", "echo $(whoami)"] {
 guard case .ask = decision(command, .smartApproval), case .ask = decision(command, .dangerFullAccess) else {
 XCTFail("不能自动放行有副作用或不透明的命令：\(command)")
 continue
 }
 }
 }

 func testBoundedTopSamplesRespectApprovalModesAndTerminalPolicy() {
 let command = #"top -b -n2 -d1 -w200 | sed -n '1,30p'"#
 func decision(_ command: String, _ mode: AgentPermissionMode, _ policy: SessionAutomationPolicy = .default) -> AgentPermissionPolicy.Decision {
 let invocation = AgentToolInvocation(id: "cpu-sample", name: AgentToolCatalog.terminalCommand, title: "采样 CPU", argumentsJSON: "{}", command: command)
 return AgentPermissionPolicy.decide(invocation: invocation, mode: mode, automation: policy)
 }
 guard case .allow = decision(command, .dangerFullAccess),
 case .allow = decision(command, .smartApproval),
 case .allow = decision(command, .dangerFullAccess, .init(aiExecutionPolicy: "readOnlyAuto")),
 case .ask = decision(command, .supervised),
 case .ask = decision(command, .dangerFullAccess, .init(environment: "production")),
 case .ask = decision(command, .dangerFullAccess, .init(aiExecutionPolicy: "requireEveryCommand")),
 case .deny = decision(command, .dangerFullAccess, .init(aiExecutionPolicy: "disabled")) else {
 return XCTFail("有限批次的 CPU 采样必须按终端及会话策略审批")
 }
 for sample in ["nproc", "cat /proc/loadavg && echo '---' && top -bn1 | head -n 20", "top -bn1", "top -b -n 2 -d 1 -w 200", "top -bn1 | head -n15", "top -b -n 1 | head -n 15", "top -bn1 | head --lines=15", "mpstat -P ALL 1 1"] {
 guard case .allow = decision(sample, .dangerFullAccess),
 case .allow = decision(sample, .smartApproval),
 case .ask = decision(sample, .supervised) else {
 XCTFail("应放行只读采样：\(sample)")
 continue
 }
 }
 for sample in ["uptime && touch /tmp/stacio-test", "top", "top -b -n20 -d1", "top -b -n2", command + " > /tmp/cpu-report", command + " /tmp/input", #"top -bn1 | sed -n 's/load/LOAD/p'"#, "top -bn1 | head -n15 /tmp/input", "top -bn1 | head -n15 | wc -l"] {
 guard case .ask = decision(sample, .dangerFullAccess) else {
 XCTFail("应要求审批：\(sample)")
 continue
 }
 }
 }

 func testInjectedBaseURLNormalization() {
 XCTAssertEqual(AgentProviderResolver.normalizedBaseURL("https://api.example.com/v1"), "https://api.example.com/v1")
 XCTAssertEqual(AgentProviderResolver.normalizedBaseURL("https://api.example.com/v1/"), "https://api.example.com/v1")
 XCTAssertEqual(AgentProviderResolver.normalizedBaseURL("https://api.example.com/v1/chat/completions"), "https://api.example.com/v1")
 XCTAssertNil(AgentProviderResolver.normalizedBaseURL("ftp://example.com"))
 XCTAssertNil(AgentProviderResolver.normalizedBaseURL(""))
 }

 func testChatCompletionsURL() {
 let url =  AgentModelClient.chatCompletionsURL(baseURL: "https://api.example.com/v1")
 XCTAssertEqual(url?.absoluteString, "https://api.example.com/v1/chat/completions")
 XCTAssertNil(AgentModelClient.chatCompletionsURL(baseURL: "not a url"))
 }

 func testDerivedTitleTruncates() {
 let title =  AgentSession.derivedTitle(from: "检查一下服务器上所有运行中的服务，并列出没有被 systemd管理的进程")
 XCTAssertLessThanOrEqual(title.count,28)
 }

 func testPromptIncludesContext() {
 let chip =  AgentContextChip(
 kind: .terminal,
 label: "web-01",
 detail: "2-40",
 uri: "terminal://t1@3",
 payload: "some output"
 )
 let text =  AgentSession.promptText(text: "看看这个", chips: [chip])
 XCTAssertTrue(text.contains("看看这个"))
 XCTAssertTrue(text.contains("terminal://t1@3"))
 XCTAssertTrue(text.contains("some output"))
 }

 func testConversationDraftIsolation() {
 var a =  AgentConversation(isDraft: true)
 var b =  AgentConversation(isDraft: true)
 a.draftText =  "alpha"
 b.draftText =  "beta"
 XCTAssertEqual(a.draftText, "alpha")
 XCTAssertEqual(b.draftText, "beta")
 }

 func testStoreRoundTrip() throws {
 let root =  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 let store =  AgentStore(rootDirectory: root, saveDebounce:0)
 var conversation =  AgentConversation(title: "测试会话")
 conversation.items.append(AgentItem(kind: .user, text: "你好"))
 store.save(conversation, immediately: true)
 let loaded =  store.loadAll()
 XCTAssertEqual(loaded.count,1)
 XCTAssertEqual(loaded.first?.title, "测试会话")
 XCTAssertEqual(loaded.first?.items.first?.text, "你好")
 try? FileManager.default.removeItem(at: root)
 }

 func testStoreLegacyBackupCopiesFiles() throws {
 let support =  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
 let legacy =  support.appendingPathComponent("agent-conversations-v2.sqlite3")
 try Data("legacy-db".utf8).write(to: legacy)

 let root =  support.appendingPathComponent("agent-v1")
 let store =  AgentStore(rootDirectory: root, saveDebounce:0)
 let copied =  store.preserveLegacyData(supportDirectory: support)
 XCTAssertTrue(copied.contains("agent-conversations-v2.sqlite3"))
 let backup =  root.appendingPathComponent("legacy-backup/agent-conversations-v2.sqlite3")
 XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
 // The original must still exist: we copy, never move.
 XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
 try? FileManager.default.removeItem(at: support)
 }

 func testMarkdownRendersHeadingsAndCode() {
 let markdown =  """
##排查结果

-服务正常
-进程33个
"""
 let rendered =  AgentMarkdownRenderer.render(markdown, width:400)
 XCTAssertGreaterThan(rendered.length,0)
 XCTAssertTrue(rendered.string.contains("排查结果"))
 XCTAssertTrue(rendered.string.contains("服务正常"))
 }

 // MARK: -性能计时

 func testTurnTimingComputesLatencyDeltas() {
 var timing =  AgentTurnTiming()
 timing.sendAt = 1.0
 timing.requestAt = 1.01
 timing.firstByteAt = 1.05
 timing.firstVisibleTextAt = 1.08
 timing.toolRequestedAt = 1.20
 timing.toolStartedAt = 1.21
 timing.toolFinishedAt = 1.45
 timing.completedAt = 1.60

 XCTAssertEqual(timing.requestLatencyMs ?? (-1),40, accuracy:0.001)
 XCTAssertEqual(timing.firstTextLatencyMs ?? (-1),70, accuracy:0.001)
 XCTAssertEqual(timing.sendToFirstTextMs ?? (-1),80, accuracy:0.001)
 XCTAssertEqual(timing.toolQueueMs ?? (-1),10, accuracy:0.001)
 XCTAssertEqual(timing.toolRunMs ?? (-1),240, accuracy:0.001)
 XCTAssertEqual(timing.turnTotalMs ?? (-1),600, accuracy:0.001)
 }

 func testTurnTimingReportsMissingMilestones() {
 let timing =  AgentTurnTiming(sendAt:1.0)
 XCTAssertNil(timing.requestLatencyMs)
 XCTAssertNil(timing.toolRunMs)
 XCTAssertTrue(timing.summary.contains("—"))
 }

 func testTurnTimingRejectsBackwardsClock() {
 var timing =  AgentTurnTiming()
 timing.requestAt = 2.0
 timing.firstByteAt = 1.0
 XCTAssertNil(timing.requestLatencyMs)
 }

 // MARK: -Inspector 接线

 /// The workbench builds its AI tab from a factory that must be assigned before
 /// the inspector loads its view. If that ordering regresses, the AI section
 /// silently becomes an empty placeholder — which is exactly what happened
 /// before, so this pins it.
 @MainActor
 func testInspectorShowsTheAgentPanelInOneSection() {
 let factoryCalled = expectation(description: "factory")
 let inspector = InspectorViewController()
 inspector.aiAssistantFactory = {
 factoryCalled.fulfill()
 return AgentPanelViewController.make(
 terminalLister: nil,
 executorResolver: InertTerminalResolver())
 }
 _ = inspector.view
 wait(for: [factoryCalled], timeout:1)

 var matches = 0
 for index in 0..<7 {
 inspector.selectSectionForTesting(index)
 if inspector.selectedContentViewControllerForTesting is AgentPanelViewController {
 matches += 1
 }
 }
 XCTAssertEqual(matches, 1, "AI页签必须解析到 AgentPanelViewController，且只出现一次")
 }

 /// An unbound terminal must fail loudly instead of reporting a fake success.
 @MainActor
 func testUnboundTerminalReportsMissingTerminal() {
 let resolver = InertTerminalResolver()
 XCTAssertThrowsError(try resolver.resolveTerminalTarget(.runtimeID("not-connected"))) { error in
 XCTAssertTrue(error is AgentExecutionError, "应为 AgentExecutionError，实际：\(error)")
 }
 }

 private struct InertTerminalResolver: AgentTerminalResolving {
 func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
 throw AgentExecutionError.terminalNotFound
 }
 }

 @MainActor
 func testExecutorRunsACommandAgainstARealShell() async throws {
 let shell = try LiveShell()
 defer { shell.terminate() }
 try await shell.waitForPrompt()
 let target = PipelineTerminalTarget(shell: shell)
 let executor = AgentTerminalExecutor(resolver: FixedTerminalResolver(target: target))

 let result = await executor.execute(
 command: #"printf 'exec-ok\n' # keep the shell comment"#,
 on: AgentTerminalExecutor.Target(runtimeID: target.runtimeID, connectionGeneration:0, title: target.runtimeID),
 onStart: {})

 XCTAssertNil(result.exitCode)
 XCTAssertEqual(result.completion, .unknown)
 XCTAssertEqual(result.output, "exec-ok")
 }

 func testSummaryOnlyRejectsUnexecutedToolCalls() throws {
 XCTAssertThrowsError(try AgentSession.validateSummaryResponse(summaryOnly: true, hasToolCalls: true))
 XCTAssertNoThrow(try AgentSession.validateSummaryResponse(summaryOnly: false, hasToolCalls: true))
 XCTAssertNoThrow(try AgentSession.validateSummaryResponse(summaryOnly: true, hasToolCalls: false))
 }

 @MainActor
 func testCustomPromptReturnsWithoutShellIntegration() async throws {
 let shell = try LiveShell(prompt: "dev ❯ ")
 defer { shell.terminate() }
 try await shell.waitForPrompt()
 let pane = PipelineTerminalTarget(shell: shell)
 let executor = AgentTerminalExecutor(resolver: FixedTerminalResolver(target: pane))
 let result = await executor.execute(command: "echo ready", on: .init(runtimeID: pane.runtimeID, connectionGeneration: 0, title: "test"), timeout: 2, onStart: {})
 XCTAssertEqual(result.completion, .unknown)
 XCTAssertEqual(result.output, "ready")
 }

 @MainActor
 func testExecutorReportsFailureFromARealShell() async throws {
 let shell = try LiveShell()
 defer { shell.terminate() }
 try await shell.waitForPrompt()
 let target = PipelineTerminalTarget(shell: shell)
 let executor = AgentTerminalExecutor(resolver: FixedTerminalResolver(target: target))

 let result = await executor.execute(
 command: "ls /definitely-not-here-exec",
 on: AgentTerminalExecutor.Target(runtimeID: target.runtimeID, connectionGeneration:0, title: target.runtimeID),
 onStart: {})

 XCTAssertNil(result.exitCode)
 XCTAssertEqual(result.completion, .unknown)
 XCTAssertTrue(result.output.contains("definitely-not-here-exec"))
 }

 @MainActor
 func testExecutorRejectsDisconnectedTerminal() async {
 let target = PipelineTerminalTarget(shell: nil)
 let executor = AgentTerminalExecutor(resolver: FixedTerminalResolver(target: target))
 let result = await executor.execute(
 command: "echo nope",
 on: AgentTerminalExecutor.Target(runtimeID: "gone", connectionGeneration:0, title: "gone"),
 onStart: {})
 XCTAssertNil(result.exitCode, "终端不可用时不应带回退出码")
 XCTAssertNotNil(result.errorMessage, "应给出错误说明，实际：\(result)")
 }

private final class LiveShell {
 private let process = Process()
 private let stdout = Pipe()
 private let stdinPipe = Pipe()
 private let lock = NSLock()
 private var buffer = ""

 let prompt: String
 init(prompt: String = "test@localhost:~$ ") throws {
 self.prompt = prompt
 process.executableURL = URL(fileURLWithPath: "/bin/bash")
 process.arguments = ["--noprofile", "--norc", "-i"]
 process.environment = ["PS1": prompt, "TERM": "dumb", "PATH": "/usr/bin:/bin"]
 process.standardOutput = stdout
 process.standardError = stdout
 process.standardInput = stdinPipe
 try process.run()
 stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
 let data = handle.availableData
 guard data.isEmpty == false, let self else { return }
 self.lock.lock()
 self.buffer += String(decoding: data, as: UTF8.self)
 self.lock.unlock()
 }
 }

 var transcript: String {
 lock.lock(); defer { lock.unlock() }
 return buffer
 }

 func waitForPrompt() async throws {
     for _ in 0..<100 {
         if transcript.hasSuffix(prompt) { return }
         try await Task.sleep(for: .milliseconds(10))
     }
     XCTFail("本地 Bash 未返回测试提示符")
     throw CocoaError(.executableLoad)
 }

 func send(_ text: String) {
 stdinPipe.fileHandleForWriting.write(Data(text.replacingOccurrences(of: "\r", with: "\n").utf8))
 }

 func terminate() {
 stdout.fileHandleForReading.readabilityHandler = nil
 stdinPipe.fileHandleForWriting.closeFile()
 if process.isRunning { process.terminate() }
 }
 }

 private final class PipelineTerminalTarget: AgentTerminalTarget {
 let shell: LiveShell?
 let runtimeID = "pipeline-target"
 init(shell: LiveShell?) { self.shell = shell }

 var isAgentRuntimeConnected: Bool { shell != nil }
 var agentTitle: String { runtimeID }
 var agentLiveSessionContext: TunnelLiveSessionContext? { nil }
 var agentTerminalOutputTranscript: String { shell?.transcript ?? "" }
 var supportsAgentCompletionMarker: Bool { true }
 func appendAgentTrace(_ event: AgentTraceEvent) {}
 func sendInput(_ bytes: [UInt8]) { shell?.send(String(decoding: bytes, as: UTF8.self)) }
 }

 private final class FixedTerminalResolver: AgentTerminalResolving {
 let target: PipelineTerminalTarget
 init(target: PipelineTerminalTarget) { self.target = target }
 func resolveTerminalTarget(_ requested: AgentTarget) throws -> AgentTerminalTarget {
 guard self.target.isAgentRuntimeConnected else {
 throw AgentExecutionError.terminalNotFound
 }
 return self.target
 }
 }

 /// Migration must preserve every legacy artefact, not just the conversation DB,
 /// and must be idempotent: running it twice must not overwrite the first backup
 /// or duplicate work.
 func testLegacyMigrationCoversAllArtefactsAndIsIdempotent() throws {
 let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

 let names = [
 "agent-conversations-v2.sqlite3",
 "assistant-settings.sqlite3",
 "assistant-settings-values-v1.json",
 "runtime-configurations-v2.sqlite3",
 "local-agent-configurations-v1.json"
 ]
 for name in names {
 try Data(("payload:" + name).utf8).write(to: support.appendingPathComponent(name))
 }

 let root = support.appendingPathComponent("agent-v1")
 let store = AgentStore(rootDirectory: root, saveDebounce:0)
 let first = store.preserveLegacyData(supportDirectory: support)
 XCTAssertEqual(Set(first), Set(names), "所有旧配置与数据库都必须被保留，实际：\(first)")

 // Every copy must be byte-identical and the originals must remain.
 for name in names {
 let backup = root.appendingPathComponent("legacy-backup/" + name)
 let original = support.appendingPathComponent(name)
 XCTAssertEqual(try Data(contentsOf: backup), try Data(contentsOf: original), name)
 XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "原文件不得被移走：" + name)
 }

 // Second run reports the same set and leaves the backups untouched.
 let second = store.preserveLegacyData(supportDirectory: support)
 XCTAssertEqual(Set(second), Set(names), "重复迁移必须幂等")
 for name in names {
 let backup = root.appendingPathComponent("legacy-backup/" + name)
 XCTAssertEqual(try Data(contentsOf: backup), try Data(("payload:" + name).utf8), name)
 }
 }

 /// The menu preview drives the state screenshots, so its rows must match what
 /// the real menus contain. Pinning both here keeps the images honest.
 @MainActor
 func testMenuPreviewRowsMatchTheRealMenus() {
 let permission = AgentMenuPreviewView.previewItems(
 for: "permission-menu",
 selectedPermissionLabel: "完全权限")
 XCTAssertEqual(permission.first?.title, "工具权限模式")
 XCTAssertEqual(permission.first?.disabled, true, "标题行不可点")
 XCTAssertEqual(permission.count,4, "标题加三个权限模式")
 let checked = permission.filter { $0.checked }.map(\.title)
 XCTAssertEqual(checked, ["完全权限"], "勾选应跟随当前模式")

 let model = AgentMenuPreviewView.previewItems(for: "model-menu")
 XCTAssertEqual(model.map(\.title), ["尚未配置模型", "-", "添加模型"])
 XCTAssertEqual(model[0].disabled, true, "未配置时该行禁用")
 XCTAssertEqual(model[1].isSeparator, true)
 }

	// MARK: -每终端一套会话

	/// A stub that reports a switchable terminal list, so the per-terminal
	/// conversation rule can be exercised without a live SSH session.
	private final class SwitchableTerminalListerInner: AgentTerminalSessionListing {
		var currentID: String
		init(currentID: String) { self.currentID = currentID }
		func listAgentTerminalSessions() -> [AgentTerminalSessionSummary] {
			["a", "b"].map { id in
				AgentTerminalSessionSummary(
					runtimeID: id,
					connectionGeneration:1,
					title: id.uppercased(),
					kind: "ssh",
					environment: "test",
					isCurrent: id == currentID,
					currentDirectory: "/home/" + id,
					subtitle: nil)
			}
		}
	}

	@MainActor
	func testEachTerminalKeepsItsOwnConversation() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let lister = SwitchableTerminalLister(currentID: "a")
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: lister,
			executorResolver: PerTerminalInertResolver())

		// Terminal A gets its own conversation.
		session.syncActiveTerminal()
		let conversationA = session.active.id
		XCTAssertEqual(session.active.boundRuntimeID, "a")

		// Switching to B must switch the conversation, not retarget A's.
		lister.currentID = "b"
		session.refreshTerminals()
		XCTAssertEqual(session.active.boundRuntimeID, "b", "切换终端必须切到该终端的会话")
		XCTAssertNotEqual(session.active.id, conversationA, "不得复用终端 A的会话")

		// Going back to A returns to A's conversation.
		lister.currentID = "a"
		session.refreshTerminals()
		XCTAssertEqual(session.active.boundRuntimeID, "a")
		XCTAssertEqual(session.active.id, conversationA, "切回终端 A应回到原会话")
	}

	@MainActor
	func testReopeningAfterPreparingRestoresTheLiveTerminalAndApprovalControls() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		let store = AgentStore(rootDirectory: root, saveDebounce: 0)
		store.save(AgentConversation(id: "prior", items: [AgentItem(kind: .assistant, text: "Partial", isStreaming: true)],
		                             phase: .preparing, boundRuntimeID: "old-runtime"), immediately: true)
		let session = AgentSession(store: store, terminalLister: SwitchableTerminalLister(currentID: "a"),
		                           executorResolver: PerTerminalInertResolver())
		XCTAssertFalse(session.isRunning)
		XCTAssertEqual(session.active.phase, .interrupted)
		XCTAssertEqual(session.active.items.first?.aborted, true)
		XCTAssertEqual(session.active.items.first?.isStreaming, false)
		session.refreshTerminals()
		XCTAssertEqual(session.active.boundRuntimeID, "a")
		XCTAssertNotNil(session.activeTerminalTitle)
		session.setPermissionMode(.smartApproval)
		XCTAssertEqual(session.active.permissionMode, .smartApproval)
	}

	@MainActor
	func testUserBubbleFitsTextAndReflowsWhenThePanelResizes() throws {
		let host = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
		let row = AgentUserMessageView(onCopy: nil)
		row.translatesAutoresizingMaskIntoConstraints = false
		host.addSubview(row)
		let width = row.widthAnchor.constraint(equalToConstant: 520)
		NSLayoutConstraint.activate([width, row.topAnchor.constraint(equalTo: host.topAnchor),
		                             row.trailingAnchor.constraint(equalTo: host.trailingAnchor)])
		let bubble = try XCTUnwrap(row.subviews.first)
		row.update(item: AgentItem(kind: .user, text: "你好"), width: 520)
		host.layoutSubtreeIfNeeded()
		XCTAssertLessThan(bubble.bounds.width, 100)
		row.update(item: AgentItem(kind: .user, text: String(repeating: "检查一下当前服务器资源使用情况。", count: 10)), width: 520)
		host.layoutSubtreeIfNeeded()
		let wide = bubble.bounds.size
		XCTAssertGreaterThan(wide.width, 400)
		width.constant = 320
		host.layoutSubtreeIfNeeded()
		host.layoutSubtreeIfNeeded()
		XCTAssertGreaterThan(bubble.bounds.width, 245)
		XCTAssertLessThan(bubble.bounds.width, wide.width)
		XCTAssertGreaterThan(bubble.bounds.height, wide.height)
	}

	/// A half-written message belongs to the conversation of the terminal it was
	/// typed in, so switching terminals must park it and restore it on return.
	@MainActor
 func testReconnectRestoresSavedSSHConversationAndPreferences() throws {
 let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 defer { try? FileManager.default.removeItem(at: root) }
 let store = AgentStore(rootDirectory: root)
 let model = AgentModelSelection(providerID: "test", providerName: "Test", modelID: "glm", modelDisplayName: "GLM")
 var chat = AgentConversation(permissionMode: .dangerFullAccess, modelSelection: model, boundRuntimeID: "old-runtime")
 chat.savedSessionID = "saved-a"
 store.save(chat, immediately: true)
 let session = AgentSession(store: store, terminalLister: SwitchableTerminalLister(currentID: "a"), executorResolver: PerTerminalInertResolver())
 session.syncActiveTerminal()
 XCTAssertEqual(session.active.id, chat.id)
 XCTAssertEqual(session.active.boundRuntimeID, "a")
 XCTAssertEqual(session.active.permissionMode, .dangerFullAccess)
 XCTAssertEqual(session.active.modelSelection, model)
 }

 @MainActor
	func testDraftSurvivesTerminalSwitch() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let lister = SwitchableTerminalLister(currentID: "a")
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: lister,
			executorResolver: PerTerminalInertResolver())

		session.syncActiveTerminal()
		let conversationA = session.active.id
		session.updateDraft("在终端 A写了一半的话")

		session.selectTerminal(runtimeID: "b")
		XCTAssertEqual(session.active.boundRuntimeID, "b")
		XCTAssertEqual(session.active.draftText, "", "切到 B不应带走 A的草稿")

		session.selectTerminal(runtimeID: "a")
		XCTAssertEqual(session.active.id, conversationA)
		XCTAssertEqual(session.active.draftText, "在终端 A写了一半的话", "切回 A必须恢复 A的草稿")
	}

	/// A draft must also survive the terminal-list refresh that runs on every poll.
	@MainActor
	func testDraftSurvivesTerminalListRefresh() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let lister = SwitchableTerminalLister(currentID: "a")
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: lister,
			executorResolver: PerTerminalInertResolver())

		session.syncActiveTerminal()
		session.updateDraft("刷新也要保住")
		session.refreshTerminals()
		XCTAssertEqual(session.active.draftText, "刷新也要保住")
	}

	


	/// The AI section must end up holding a real panel once the window supplies a
	/// factory. This is the wiring that a nil factory silently broke: the section
	/// kept an empty placeholder for the whole session.
	@MainActor
	func testInspectorWiresTheAIPanelFromItsFactory() throws {
		let inspector = InspectorViewController(
			transferHistoryStore: NoOpSCPTransferHistoryStore(),
			workspaceSessionProtocolProvider: { .noSession })
		let panel = AgentPanelViewController.make(
			terminalLister: nil,
			executorResolver: PerTerminalInertResolver())
		inspector.aiAssistantFactory = { panel }
		_ = inspector.view
		XCTAssertTrue(
			inspector.aiAssistantViewController === panel,
			"工厂提供的面板必须成为 AI分节的控制器")
	}

	/// The panel must lay out to usable geometry at the inspector's real width.
	@MainActor
	func testPanelSettlesAtInspectorWidth() throws {
		let panel = AgentPanelViewController.make(
			terminalLister: nil,
			executorResolver: PerTerminalInertResolver())
		let host = NSView(frame: NSRect(x:0, y:0, width:320, height:900))
		panel.view.translatesAutoresizingMaskIntoConstraints = true
		panel.view.autoresizingMask = [.width, .height]
		panel.view.frame = host.bounds
		host.addSubview(panel.view)
		panel.view.layoutSubtreeIfNeeded()
		let conversation = panel.conversationViewForTesting
		XCTAssertNotNil(conversation, "panel must expose its transcript")
		XCTAssertGreaterThan(conversation?.bounds.width ?? 0, 200,
			"chat column width, got \(conversation?.bounds.width ?? 0)")
		XCTAssertGreaterThan(conversation?.bounds.height ?? 0, 300,
			"chat column height, got \(conversation?.bounds.height ?? 0)")
	}

	/// The same panel hosted by a real window, which is the path that used to abort.
	@MainActor
	func testPanelRendersInsideARealWindow() throws {
		let window = NSWindow(
			contentRect: NSRect(x:0, y:0, width:320, height:800),
			styleMask: [.titled, .resizable],
			backing: .buffered,
			defer: false)
		let panel = AgentPanelViewController.make(
			terminalLister: nil,
			executorResolver: PerTerminalInertResolver())
		window.contentViewController = panel
		window.layoutIfNeeded()
		panel.view.layoutSubtreeIfNeeded()
		let conversation = panel.conversationViewForTesting
		XCTAssertNotNil(conversation?.superview, "transcript must be in the view tree")
		XCTAssertGreaterThan(conversation?.bounds.width ?? 0, 200,
			"chat column width in a window, got \(conversation?.bounds.width ?? 0)")

		func findApproval(in view: NSView) -> AgentApprovalView? {
			(view as? AgentApprovalView) ?? view.subviews.lazy.compactMap { findApproval(in: $0) }.first
		}
		panel.showApprovalForHarness()
		panel.view.layoutSubtreeIfNeeded()
		let approval = try XCTUnwrap(findApproval(in: panel.view))
		XCTAssertNil(findApproval(in: try XCTUnwrap(conversation)))
		let cardFrame = approval.convert(approval.bounds, to: nil)
		let composer = panel.composerForTesting
		XCTAssertGreaterThan(cardFrame.height, 150)
		XCTAssertEqual(cardFrame.minY - composer.convert(composer.bounds, to: nil).maxY, 8, accuracy: 1)
		panel.loadTranscriptEntriesForPerformanceTesting(count: 40)
		XCTAssertEqual(approval.convert(approval.bounds, to: nil), cardFrame)
	}

	/// The composer must turn a draft into a user turn. Without this the panel looks
	/// alive but nothing can ever be sent.
	@MainActor
	func testDraftBecomesAUserTurnOnSend() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: nil,
			executorResolver: PerTerminalInertResolver())

		session.updateDraft("hello from the test")
		XCTAssertEqual(session.active.draftText, "hello from the test", "draft must be recorded")

		session.send()
		let userItems = session.active.items.filter { $0.kind == .user }
		XCTAssertEqual(userItems.count,1, "sending must append one user turn")
		XCTAssertEqual(userItems.first?.text, "hello from the test")
		XCTAssertEqual(session.active.draftText, "", "draft must clear after send")
	}

	/// End to end through the panel: a draft typed into the composer must become a
	/// user turn and be rendered into the transcript.
	@MainActor
	func testComposerDraftReachesTheTranscript() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: nil,
			executorResolver: PerTerminalInertResolver())
		let panel = AgentPanelViewController(session: session)
		_ = panel.view
		panel.view.layoutSubtreeIfNeeded()

		// Drive the same entry point the text view uses.
		panel.composerForTesting.setTextForTesting("list the disk")
		XCTAssertEqual(session.active.draftText, "list the disk",
			"typing must reach the session draft")

		panel.composerForTesting.sendForTesting()
		XCTAssertEqual(session.active.items.filter { $0.kind == .user }.count,1,
			"sending must create exactly one user turn")
		XCTAssertEqual(session.active.draftText, "")
	}

 func testModelIconUsesModelFamilyThroughACompatibleProvider() throws {
 func selection(_ modelID: String) -> AgentModelSelection {
 AgentModelSelection(providerID: "gateway", providerName: "OpenAI Compatible",
                     modelID: modelID, modelDisplayName: "Custom display name")
 }
 let deepseek = try XCTUnwrap(selection("gateway/deepseek-v4.1").pickerIcon())
 let claude = try XCTUnwrap(selection("anthropic/claude-sonnet").pickerIcon())
 XCTAssertFalse(deepseek.isTemplate)
 XCTAssertFalse(claude.isTemplate)
 XCTAssertFalse(deepseek === claude)
 let kimi = try XCTUnwrap(selection("kimi-k2").pickerIcon())
 XCTAssertTrue(selection("openai/kimi-k2").pickerIcon() === kimi)
 XCTAssertFalse(kimi.isTemplate)
 let hunyuan = try XCTUnwrap(selection("hunyuan").pickerIcon())
 let yuanbao = try XCTUnwrap(selection("yuanbao").pickerIcon())
 XCTAssertNotEqual(try XCTUnwrap(hunyuan.tiffRepresentation), try XCTUnwrap(yuanbao.tiffRepresentation))
 for brand in ["opencode", "hermesagent", "happyhorse", "agnesai", "stepfun"] {
     XCTAssertTrue(try XCTUnwrap(selection(brand).pickerIcon()).isTemplate)
 }
 }

 func testComposerDoesNotSendUncommittedIMEText() {
 let composer = AgentComposerView(frame: .zero)
 var draft = ""
 var sent = 0
 composer.onDraftChange = { draft = $0 }
 composer.onSend = { sent += 1 }
 composer.sendForTesting()
 XCTAssertEqual(sent, 0)

 let input = composer.textInput
 XCTAssertTrue(composer.isPlaceholderVisibleForTesting)
 input.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                     replacementRange: NSRange(location: NSNotFound, length: 0))
 XCTAssertTrue(input.hasMarkedText())
 XCTAssertFalse(composer.isPlaceholderVisibleForTesting)
 composer.sendForTesting()
 XCTAssertEqual(sent, 0)
 XCTAssertEqual(draft, "")

 input.insertText("你", replacementRange: NSRange(location: NSNotFound, length: 0))
 XCTAssertFalse(input.hasMarkedText())
 XCTAssertEqual(draft, "你")
 XCTAssertFalse(composer.isPlaceholderVisibleForTesting)
 composer.sendForTesting()
 XCTAssertEqual(sent, 1)
 }

	/// The JSON written into defaults must decode; otherwise the resolver sees no
	/// providers and every turn fails with "尚ene configured".
	func testProviderEnvelopeJSONDecodes() throws {
		let json = """
		{"formatVersion":1,"defaultAIProviderID":"00000000-0000-0000-0000-0000000000AA",\
		"aiProviders":[{"id":"00000000-0000-0000-0000-0000000000AA",\
		"profile":"OpenAI Compatible","displayName":"tokenmetro",\
		"baseURL":"https://tokenmetro.icu/v1",\
		"models":[{"id":"deepseek-v4.1-flash-1017","isEnabled":true,"isManual":true,\
		"wasReturnedByLatestCatalog":false,"capabilities":{"contextCharacterLimitSource":"unknown","supportedReasoningEffortsSource":"unknown","reasoningEffortSource":"unknown"}}],\
		"defaultModelID":"deepseek-v4.1-flash-1017",\
		"compatibilityProtocol":"chatCompletions","maxRetryCount":1,\
		"requestTimeoutSeconds":60,"userAgent":"Stacio","isEnabled":true}]}
		"""
		let data = Data(json.utf8)
		let decoded = try JSONDecoder().decode(AIProviderSettingsEnvelope.self, from: data)
		XCTAssertEqual(decoded.aiProviders.count,1, "one provider must decode")
		XCTAssertEqual(decoded.aiProviders.first?.defaultModelID, "deepseek-v4.1-flash-1017")
	}

	/// Writes a throwaway credential through the same store the app reads.
	/// Kept as a test so the sealed vault entry is produced by production code.
	/// The value is a placeholder on purpose: never commit a real key here.
	func testStoreProviderCredential() throws {
		let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
		let store = KeychainAIApiKeyStore()
		let secret = "sk-test-placeholder-not-a-real-credential"
		try store.saveAPIKey(secret, for: providerID)
		XCTAssertEqual(try store.readAPIKey(for: providerID), secret,
			"credential must round-trip through the store")
	}

 func testStopButtonInterruptsRunningTerminalCommand() async throws {
 let terminal = SilentTerminalTarget()
 let executor = AgentTerminalExecutor(resolver: StalledTerminalResolver(target: terminal))
 let target = AgentTerminalExecutor.Target(runtimeID: terminal.runtimeID, connectionGeneration: 1, title: "silent")
 let commandSent = expectation(description: "command entered the bound terminal")
 let command = Task { await executor.execute(command: "sleep 30", on: target, onStart: { commandSent.fulfill() }) }
 await fulfillment(of: [commandSent], timeout: 2)
 XCTAssertTrue(terminal.agentInputs.first.map { String(decoding: $0, as: UTF8.self).contains("sleep 30") } ?? false)

 let composer = AgentComposerView(frame: .zero)
 composer.applyRunning(true)
 composer.applyApprovalPending(true)
 composer.textInput.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
 XCTAssertTrue(composer.textInput.isEditable)
 XCTAssertTrue(composer.textInput.hasMarkedText())
 composer.onStop = { XCTAssertTrue(executor.cancelActive()) }
 composer.sendForTesting()
 XCTAssertEqual(terminal.agentInputs.last, [0x03])
 XCTAssertFalse(executor.hasActiveExecution)
 let result = await command.value
 XCTAssertTrue(result.wasCancelled)
 XCTAssertEqual(result.completion, .unconfirmed)
 }

	/// A terminal that accepts input but never reports the completion marker. The
	/// turn must still finish as unconfirmed instead of hanging forever, which is the
	/// deadlock that blocked every later message.
	@MainActor
	func testStalledCommandSettlesAsUnconfirmed() async throws {
		let terminal = SilentTerminalTarget()
		let resolver = StalledTerminalResolver(target: terminal)
		let executor = AgentTerminalExecutor(resolver: resolver)
		executor.commandTimeout = 0.6
		let target = AgentTerminalExecutor.Target(
			runtimeID: terminal.agentRuntimeIDForTesting,
			connectionGeneration: 0,
			title: "silent")

		let started = Date()
		let result = await executor.execute(command: "sleep999", on: target, onStart: {})
		let elapsed = Date().timeIntervalSince(started)

		XCTAssertLessThan(elapsed,8, "执行必须在截止时间后结束，实际 \(elapsed)秒")
		XCTAssertNotNil(result.errorMessage, "超时必须报告未确认原因")
		XCTAssertTrue(result.completion == .unconfirmed, "超时不能被标记为已确认")
	}

	/// A terminal that answers with the real completion marker, so the successful
	/// path through the executor is covered rather than only the timeout path.
	@MainActor
	func testLiteralCommandWithShellEventsSettlesAsConfirmed() async throws {
		let terminal = EchoingTerminalTarget()
		let resolver = EchoingTerminalResolver(target: terminal)
		let executor = AgentTerminalExecutor(resolver: resolver)
		executor.commandTimeout = 3
		executor.pollInterval = 0.02
		let target = AgentTerminalExecutor.Target(
			runtimeID: terminal.runtimeID,
			connectionGeneration: 1,
			title: "echo")

		let command = #"printf 'hello\n' | head -n 1"#
		let result = await executor.execute(command: command, on: target, onStart: {})
		XCTAssertEqual(terminal.input, command + "\r")
		XCTAssertEqual(result.completion, .confirmed, "带标记的输出必须判定为已确认")
		XCTAssertEqual(result.exitCode,0, "退出码应被解析出来")
		XCTAssertTrue(result.output.contains("hello"), "输出应包含命令结果，实际\(result.output)")
		XCTAssertNil(result.errorMessage, "成功执行不应带错误")
	}

	/// Approval actions must be safe when nothing is pending, and stop must stay
	/// idempotent, because the buttons remain clickable after a turn ends.
	@MainActor
	func testApprovalActionsAreSafeWhenIdle() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: nil,
			executorResolver: PerTerminalInertResolver())

		XCTAssertNil(session.pendingApproval, "新会话不应有待审批请求")

		// These are reachable from the UI even with no pending request.
		session.approvePending(.once)
		session.rejectPending()
		session.stop()
		session.stop()

		XCTAssertFalse(session.isRunning, "空闲时调用停止不应进入运行状态")
		XCTAssertNil(session.pendingApproval)
		session.updateDraft("still editable")
		XCTAssertEqual(session.active.draftText, "still editable", "操作后草稿仍可编辑")
	}

	/// Switching to a different terminal must land in that terminal's own
	/// conversation, not reuse the previous one.
	@MainActor
	func testSwitchingTerminalSelectsThatTerminalsConversation() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let lister = SwitchableTerminalLister(currentID: "a")
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: lister,
			executorResolver: PerTerminalInertResolver())
		session.refreshTerminals()

		session.updateDraft("draft on a")
		session.selectTerminal(runtimeID: "b")

		XCTAssertEqual(session.active.boundRuntimeID, "b", "切换后必须绑定到新终端")
		XCTAssertNotEqual(session.active.draftText, "draft on a", "不能把上一个终端的草稿带过来")

		session.selectTerminal(runtimeID: "a")
		XCTAssertEqual(session.active.boundRuntimeID, "a", "切回时必须回到原终端")
		XCTAssertEqual(session.active.draftText, "draft on a", "原终端草稿必须保留")
	}

	/// A command whose marker never arrives must end as unconfirmed within the
	/// deadline, and the settle must not depend on onFinish having been attached.
	@MainActor
	func testDeadlineSettlesWithoutMarker() async throws {
		let terminal = SilentTerminalTarget()
		let resolver = StalledTerminalResolver(target: terminal)
		let executor = AgentTerminalExecutor(resolver: resolver)
		executor.commandTimeout = 0.5
		executor.pollInterval = 0.05
		let target = AgentTerminalExecutor.Target(
			runtimeID: terminal.runtimeID,
			connectionGeneration:1,
			title: "silent")

		let start = Date()
		let result = await executor.execute(command: "sleep999", on: target, onStart: {})
		let elapsed = Date().timeIntervalSince(start)

		XCTAssertLessThan(elapsed,5, "必须在截止时间附近结束，实际\(elapsed)秒")
		XCTAssertEqual(result.completion, .unconfirmed, "超时不能报成功")
		XCTAssertNotNil(result.errorMessage)
	}


    @MainActor
    func testLongCommandKeepsTerminalUntilShellFinishes() async throws {
        let pane = ShellEventTerminal()
        pane.completesImmediately = false
        let executor = AgentTerminalExecutor(resolver: ShellEventResolver(target: pane))
        executor.commandTimeout = 0.02
        executor.pollInterval = 0.01
        let target = AgentTerminalExecutor.Target(runtimeID: pane.runtimeID, connectionGeneration: 1, title: "test")
        let install = Task { await executor.execute(command: "install", on: target, timeout: .infinity, onStart: {}) }
        try await Task.sleep(nanoseconds: 100_000_000)
        pane.sent += "17%"
        pane.agentCommandCompletionGeneration += 1
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(executor.hasActiveExecution)
        let reads = pane.transcriptReads
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(pane.transcriptReads, reads)
        let busy = await executor.execute(command: "probe", on: target, onStart: {})
        XCTAssertNotNil(busy.errorMessage)
        XCTAssertEqual(pane.inputs.count, 1)
        pane.finishCommand(with: "installed")
        let finished = await install.value
        XCTAssertEqual(finished.exitCode, 0)
        _ = await executor.execute(command: "slow", on: target, onStart: {})
        _ = await executor.execute(command: "probe", on: target, onStart: {})
        XCTAssertEqual(pane.inputs.count, 2)
        pane.finishCommand(with: "ready")
        pane.completesImmediately = true
        let verified = await executor.execute(command: "verify", on: target, onStart: {})
        XCTAssertEqual(verified.exitCode, 0)
        XCTAssertEqual(pane.inputs.count, 3)
    }

	func testModelCannotRedirectABoundTurnToAnotherTerminal() {
		let bound = AgentTerminalExecutor.Target(runtimeID: "original", connectionGeneration: 3, title: "Original")
		XCTAssertEqual(AgentSession.resolveTurnTarget(bound, requestedID: nil), bound)
		XCTAssertEqual(AgentSession.resolveTurnTarget(bound, requestedID: "original"), bound)
		XCTAssertNil(AgentSession.resolveTurnTarget(bound, requestedID: "another"))
		XCTAssertNil(AgentSession.resolveTurnTarget(nil, requestedID: "original"))
	}

    func testFailedCommandIsNotResentInTheSameTurn() async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let terminal = ShellEventTerminal()
        terminal.immediateOutput = "mpstat11: command not found\n"
        terminal.exitStatus = ""
        let session = AgentSession(store: AgentStore(rootDirectory: support, saveDebounce: 0),
                                   terminalLister: FixedTerminalLister(), executorResolver: ShellEventResolver(target: terminal))
        let turn = Task {
            await session.runToolForTesting(name: AgentToolCatalog.terminalCommand, arguments: #"{"command":"mpstat11","terminal_id":"t1"}"#, permission: .dangerFullAccess, repeating: true, followUpArguments: #"{"command":"uptime","terminal_id":"t1"}"#)
        }
        let approval = expectation(description: "initial unclassified command requires approval")
        session.onChange = { change in
            if case .approval = change, session.pendingApproval != nil { approval.fulfill() }
        }
        await fulfillment(of: [approval], timeout: 2)
        session.approvePending(.once)
        _ = await turn.value
        XCTAssertEqual(terminal.inputs, ["mpstat11\r", "uptime\r"])
        let tools = session.active.items.compactMap(\.tool)
        XCTAssertEqual(tools.prefix(2).map(\.status), [.failure, .rejected])
        XCTAssertNil(tools.first?.exitCode)
        XCTAssertTrue(tools[1].output.contains("已阻止重复执行") == true)
        XCTAssertNotNil(AgentSession.shellFailureDiagnostic(command: "curl --max-time10", output: "curl: option --max-time10: is unknown"))
        XCTAssertNotNil(AgentSession.shellFailureDiagnostic(command: "mpstat -P ALL11", output: "Usage: mpstat [ options ]"))
    }

	@MainActor
	func testApprovedToolRunsThroughTheExecutor() async throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let terminal = ShellEventTerminal()
		terminal.completesImmediately = false
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: FixedTerminalLister(),
			executorResolver: ShellEventResolver(target: terminal))

        let approvalShown = expectation(description: "terminal command waits for approval")
        let partialOutput = expectation(description: "terminal output arrives before the completion marker")
        session.onChange = { change in
            if case .approval = change, session.pendingApproval != nil { approvalShown.fulfill() }
            if case .streaming(let id) = change,
               let row = session.active.items.last, row.id == id,
               row.tool?.output == "first line" {
                XCTAssertEqual(row.tool?.status, .running)
                partialOutput.fulfill()
            }
        }
        let turn = Task {
            await session.runToolForTesting(
                name: "execute_terminal_command",
                arguments: #"{"command":"mkdir -p /tmp/x","terminal_id":"t1","purpose_zh":"在临时目录中创建 x 目录。"}"#,
                permission: .supervised)
        }
        await fulfillment(of: [approvalShown], timeout: 2)
        let approvalRow = session.active.items.last
        XCTAssertEqual(approvalRow?.tool?.status, .awaitingApproval)
        XCTAssertEqual(session.pendingApproval?.commandPurpose, "在临时目录中创建 x 目录。")
        XCTAssertFalse(terminal.sentContains("mkdir"))
        session.setPermissionMode(.dangerFullAccess)
        XCTAssertEqual(session.active.permissionMode, .supervised)
        XCTAssertNotNil(session.pendingApproval)
        session.approvePending(.once)
        await fulfillment(of: [partialOutput], timeout: 2)
        terminal.finishCommand(with: "second line\n")
        _ = await turn.value
        session.onChange = nil
		// The turn continues to the model after the tool, which needs a provider this
		// test does not configure. What matters here is the tool itself.
		XCTAssertTrue(terminal.sentContains("mkdir"), "命令必须到达终端")
		let tool = session.active.items.first { $0.kind == .tool }?.tool
		let rows = session.active.items.filter { $0.kind == .tool }
		XCTAssertEqual(rows.map(\.id), [approvalRow?.id].compactMap { $0 })
		XCTAssertEqual(tool?.terminalTitle, "test")
		XCTAssertEqual(tool?.output, "first line\nsecond line")
		XCTAssertNotNil(tool, "必须记录工具卡片")
		XCTAssertNotEqual(tool?.status, .running, "执行结束后卡片不能停在运行中")
		XCTAssertEqual(tool?.status, .success, "命令执行成功，实际：\(String(describing: tool?.status)) \(tool?.output ?? "") \(tool?.errorMessage ?? "")")
	}
}


private struct PerTerminalInertResolver: AgentTerminalResolving {
	func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
		throw AgentExecutionError.terminalNotFound
	}

	/// Picking a terminal switches to that terminal's conversation, and the
	/// switch is refused while a turn is running so a question cannot jump hosts.
	@MainActor
	func testSelectingTerminalSwitchesConversation() throws {
		let support = FileManager.default.temporaryDirectory
			.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
		let lister = SwitchableTerminalLister(currentID: "a")
		let session = AgentSession(
			store: AgentStore(rootDirectory: support, saveDebounce:0),
			terminalLister: lister,
			executorResolver: PerTerminalInertResolver())

		session.syncActiveTerminal()
		let conversationA = session.active.id
		XCTAssertEqual(session.active.boundRuntimeID, "a")

		session.selectTerminal(runtimeID: "b")
		XCTAssertEqual(session.active.boundRuntimeID, "b", "选中终端 B必须切到 B的会话")
		XCTAssertNotEqual(session.active.id, conversationA)

		session.selectTerminal(runtimeID: "a")
		XCTAssertEqual(session.active.id, conversationA, "选回 A必须回到原会话")
	}
}

private final class SwitchableTerminalLister: AgentTerminalSessionListing {
	var currentID: String
	init(currentID: String) { self.currentID = currentID }
	func listAgentTerminalSessions() -> [AgentTerminalSessionSummary] {
		["a", "b"].map { id in
			AgentTerminalSessionSummary(
				runtimeID: id,
				connectionGeneration:1,
				title: id.uppercased(),
				kind: "ssh",
				environment: "test",
				isCurrent: id == currentID,
				currentDirectory: "/home/" + id,
				subtitle: nil, savedSessionID: "saved-" + id)
		}
	}
}

/// A terminal that accepts input and reports nothing back, so the executor can only
/// finish through its own deadline.
@MainActor
final class SilentTerminalTarget: AgentTerminalTarget {
	@MainActor var runtimeID: String { "silent-terminal" }
	var agentLiveSessionContext: TunnelLiveSessionContext? { nil }
	let agentRuntimeIDForTesting = "silent-terminal"
	var agentRuntimeGeneration: UInt64 {1 }
	var isAgentRuntimeConnected: Bool { true }
	var agentTitle: String { "silent" }
	var agentCommandCompletionGeneration: UInt64 {1 }
	var agentTerminalOutputTranscript: String { "" }
	var agentTerminalDisplaySnapshot: String { "" }
	var supportsAgentCompletionMarker: Bool { true }
	var isAwaitingSensitiveInput: Bool { false }
	var isSensitiveInputProtectionActive: Bool { false }
	func setAgentInteractionLocked(_ locked: Bool) {}
	func refreshAgentTerminalOutput() {}
	func appendAgentTrace(_ event: AgentTraceEvent) {}
	func sendInput(_ bytes: [UInt8]) {}
	@discardableResult func sendAgentInput(_ bytes: [UInt8]) -> Bool {
		agentInputs.append(bytes)
		return true
	}
	private(set) var agentInputs: [[UInt8]] = []
	@discardableResult func sendSensitiveUserInput(_ bytes: [UInt8]) -> Bool { true }
}

struct StalledTerminalResolver: AgentTerminalResolving {
	let target: AgentTerminalTarget
	func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
		return self.target
	}
}

/// Emits a shell integration start/end pair after receiving the original command.
@MainActor
final class EchoingTerminalTarget: AgentTerminalTarget {
	var runtimeID: String { "echo-terminal" }
	var agentLiveSessionContext: TunnelLiveSessionContext? { nil }
	var agentRuntimeGeneration: UInt64 {1 }
	var isAgentRuntimeConnected: Bool { true }
	var agentTitle: String { "echo" }
	var agentCommandCompletionGeneration: UInt64 {1 }
	var supportsAgentCompletionMarker: Bool { true }
	var isAwaitingSensitiveInput: Bool { false }
	var isSensitiveInputProtectionActive: Bool { false }
	var sent = ""
	var input = ""
	var agentTerminalOutputTranscript: String { sent }
	var agentTerminalDisplaySnapshot: String { sent }
	func setAgentInteractionLocked(_ locked: Bool) {}
	func refreshAgentTerminalOutput() {}
	func appendAgentTrace(_ event: AgentTraceEvent) {}
	func sendInput(_ bytes: [UInt8]) {}
	@discardableResult func sendAgentInput(_ bytes: [UInt8]) -> Bool {
        input = String(decoding: bytes, as: UTF8.self)
        sent = input + "\n\u{1B}]133;C\u{07}hello\n\u{1B}]133;D;0\u{07}"
		return true
	}
	@discardableResult func sendSensitiveUserInput(_ bytes: [UInt8]) -> Bool { true }
}

struct EchoingTerminalResolver: AgentTerminalResolving {
	let target: AgentTerminalTarget
	func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
		return self.target
	}
}

/// Supplies live output and independently reports shell completion.
@MainActor
final class ShellEventTerminal: AgentTerminalTarget {
	var runtimeID: String { "t1" }
	var agentLiveSessionContext: TunnelLiveSessionContext? { nil }
	var agentRuntimeGeneration: UInt64 {1 }
	var isAgentRuntimeConnected: Bool { true }
	var agentTitle: String { "test" }
	var agentCommandCompletionGeneration: UInt64 = 1
	var supportsAgentCompletionMarker: Bool { true }
	var isAwaitingSensitiveInput: Bool { false }
	var isSensitiveInputProtectionActive: Bool { false }
	var sent = ""
	var completesImmediately = true
    var immediateOutput = "done\n"
    var exitStatus = ";0"
    private(set) var inputs: [String] = []
	var agentOutputPosition: Int { sent.utf8.count }
    private(set) var transcriptReads = 0
    var agentTerminalOutputTranscript: String { transcriptReads += 1; return sent }
	var agentTerminalDisplaySnapshot: String { sent }
	func setAgentInteractionLocked(_ locked: Bool) {}
	func refreshAgentTerminalOutput() {}
	func appendAgentTrace(_ event: AgentTraceEvent) {}
	func sendInput(_ bytes: [UInt8]) {}
	@discardableResult func sendAgentInput(_ bytes: [UInt8]) -> Bool {
        let input = String(decoding: bytes, as: UTF8.self)
        inputs.append(input)
        sent += input + "\n\u{1B}]133;C\u{07}"
        if completesImmediately {
            finishCommand(with: immediateOutput)
        } else {
            sent += "first line\n"
        }
        return true
    }
    func finishCommand(with output: String) {
        sent += output + "\u{1B}]133;D\(exitStatus)\u{07}"
    }
	@discardableResult func sendSensitiveUserInput(_ bytes: [UInt8]) -> Bool { true }
	func sentContains(_ needle: String) -> Bool { sent.contains(needle) }
}

struct ShellEventResolver: AgentTerminalResolving {
	let target: AgentTerminalTarget
	func resolveTerminalTarget(_ target: AgentTarget) throws -> AgentTerminalTarget {
		return self.target
	}
}


/// Keeps the stubbed terminal visible to the mid-turn refresh.
struct FixedTerminalLister: AgentTerminalSessionListing {
	func listAgentTerminalSessions() -> [AgentTerminalSessionSummary] {
		return [AgentTerminalSessionSummary(
			runtimeID: "t1",
			connectionGeneration:1,
			title: "test",
			kind: "local",
			environment: "",
			isCurrent: true,
			currentDirectory: nil,
			subtitle: nil)]
	}
}

private final class PromptEnhancementKeyStore: AIApiKeyStoring {
 func saveAPIKey(_ apiKey: String, for providerID: UUID) throws {}
 func readAPIKey(for providerID: UUID) throws -> String? { "test-key" }
 func deleteAPIKey(for providerID: UUID) throws {}
}

private final class PromptEnhancementURLProtocol: URLProtocol {
 private static let cancellationLock = NSLock()
 private static var cancellationStarted: XCTestExpectation?
 private static var cancellationStopped: XCTestExpectation?
 private var stoppedExpectation: XCTestExpectation?

 static func setCancellationExpectations(started: XCTestExpectation?, stopped: XCTestExpectation?) {
 cancellationLock.lock()
 defer { cancellationLock.unlock() }
 cancellationStarted = started
 cancellationStopped = stopped
 }

 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
 Self.cancellationLock.lock()
 let started = Self.cancellationStarted
 stoppedExpectation = Self.cancellationStopped
 Self.cancellationLock.unlock()
 if let started {
 started.fulfill()
 return
 }
 var body = request.httpBody
 if body == nil, let stream = request.httpBodyStream {
 stream.open()
 defer { stream.close() }
 var bytes = [UInt8](repeating: 0, count: 1024)
 var data = Data()
 while true {
 let length = stream.read(&bytes, maxLength: bytes.count)
 if length <= 0 { break }
 data.append(contentsOf: bytes.prefix(length))
 }
 body = data
 }
 let payload = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
 let valid = request.url?.path == "/v1/chat/completions"
 && payload?["model"] as? String == "deepseek-chat"
 && payload?["stream"] as? Bool == false && payload?["tools"] == nil
 let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 400,
 httpVersion: nil, headerFields: nil)!
 client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
 client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"content":"检查磁盘使用情况"},"finish_reason":"stop"}]}"#.utf8))
 client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() { stoppedExpectation?.fulfill() }
}
