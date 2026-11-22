import Foundation

/// The single source of truth for the AI panel.
///
/// One session owns one conversation at a time. The transcript, composer, status
/// strip and approval card all read from this object and are notified through
/// `onChange`; no second copy of message, tool or phase state exists.
///
/// Turn pipeline: conversation, user turn, model response, tool request,
/// permission decision, execution, tool result, follow-up response.
@MainActor
final class AgentSession {
 enum Change {
 case conversationList
 case transcript
 case streaming(itemID: String)
 case composer
 case phase
 case approval
 }

 private let store: AgentStore
 private let providerResolver: AgentProviderResolver
 private let modelClient: AgentModelClient
 private let promptEnhancer: AgentPromptEnhancer
 private let executor: AgentTerminalExecutor
 private let terminalLister: AgentTerminalSessionListing?

 private(set) var conversations: [AgentConversation] = []
 private(set) var active: AgentConversation {
 didSet {
 if oldValue.id != active.id { resetEnhancement() }
 }
 }
 private(set) var availableModels: [AgentModelSelection] = []
	/// How long an unanswered approval card may hold the turn before it is treated
	/// as a rejection.
	var approvalTimeoutSeconds: TimeInterval = 600
 private(set) var pendingApproval: AgentApprovalRequest?
 private(set) var terminals: [AgentTerminalSessionSummary] = []
 private(set) var legacyBackupNotice: String?

 private var historyObserver: NSObjectProtocol?
 private var turnPreferences = AppSettings()
 /// The UI describes the same snapshot used by an active turn.
 var permissionPreferences: AppSettings {
     isRunning ? turnPreferences : AppSettingsStore.shared.snapshot()
 }
 private var turnContextLimit = AIModelCapabilityConfiguration.defaultContextCharacterLimit
 private var turnToolCount = 0
 private var turnSettings: AssistantRuntimeSettingsSnapshot?
 private static func settings() -> AssistantRuntimeSettingsSnapshot? {
 try? AssistantRuntimeSettingsSnapshot.resolve(from: AssistantSettingsLiveStore.sharedIfAvailable())
 }
 private var wireMessages: [[String: Any]] = []
 private var terminalWaitDuration: TimeInterval = 0
 private(set) var turnTiming = AgentTurnTiming()
 private var toolCallBuffer: [Int: AgentModelClient.ToolCallAccumulator] = [:]
 private var inFlightTurn: Task<Void, Never>?
 private var turnTarget: AgentTerminalExecutor.Target?
 private var commandsThatMustNotBeRetried = Set<String>()
 private var approvalContinuation: CheckedContinuation<AgentApprovalGrant?, Error>?

 var onChange: ((Change) -> Void)?

 init(store: AgentStore = .shared, providerResolver: AgentProviderResolver = AgentProviderResolver(), modelClient: AgentModelClient = AgentModelClient(), promptEnhancer: AgentPromptEnhancer = AgentPromptEnhancer(), terminalLister: AgentTerminalSessionListing? = nil, executorResolver: AgentTerminalResolving) {
 self.store = store
 self.providerResolver = providerResolver
 self.modelClient = modelClient
 self.promptEnhancer = promptEnhancer
 self.terminalLister = terminalLister
 self.executor = AgentTerminalExecutor(resolver: executorResolver)

 let settings = Self.settings()
 if let days = settings?.historyRetentionDays { store.removeHistory(before: Date().addingTimeInterval(-Double(days) * 86400)) }
 let loaded = store.loadAll().map { conversation in
 var conversation = conversation

 // Persisted conversations cannot own a live task after the panel is recreated.
 if conversation.phase.isActive { conversation.phase = .interrupted }
 for index in conversation.items.indices {
 if conversation.items[index].kind == .assistant {
 var filter = AgentVisibleResponse()
 let visible = filter.append(conversation.items[index].text) + filter.finish()
 if filter.sawProtocol {
 conversation.items[index].text = visible.isEmpty ? "模型返回了无效的工具调用。" : visible
 conversation.items[index].aborted = true
 }
 }

 if conversation.items[index].isStreaming {
 conversation.items[index].isStreaming = false
 conversation.items[index].aborted = true
 }
 switch conversation.items[index].tool?.status {
 case .awaitingApproval:
 conversation.items[index].tool?.status = .cancelled
 case .running:
 conversation.items[index].tool?.status = .failure
 conversation.items[index].tool?.completionState = .unconfirmed
 conversation.items[index].tool?.errorMessage = "上次会话已中断，未确认终端命令是否结束。"
 default: break
 }
 }
 return conversation
 }
 self.conversations = loaded
 if let first = loaded.first, Self.settings()?.restoreLastConversationEnabled != false {
 self.active = first
 } else {
 self.active = AgentConversation(isDraft: true)
 }
 self.availableModels = providerResolver.modelChoices()
 if self.active.modelSelection == nil {
 self.active.modelSelection = providerResolver.defaultSelection()
 }
 refreshModels()
 let copied = store.preserveLegacyData()
 if copied.isEmpty == false {
 self.legacyBackupNotice = "已保留旧版 AI数据副本（\(copied.count)个文件），可在应用支持目录的 agent-v1/legacy-backup查看。"
 }
 self.terminals = terminalLister?.listAgentTerminalSessions() ?? []
 if settings?.restoreLastConversationEnabled == false, let current = terminals.first(where: { $0.isCurrent }) {
 active.boundRuntimeID = current.runtimeID
 active.savedSessionID = current.savedSessionID
 active.boundConnectionGeneration = current.connectionGeneration
 }
 restoreWireHistory()
 historyObserver = NotificationCenter.default.addObserver(forName: AgentStore.historyRemoved, object: nil, queue: .main) { [weak self, weak store] note in
 guard let source = note.object as? AgentStore, source === store, let ids = note.userInfo?["ids"] as? Set<String> else { return }
 MainActor.assumeIsolated {
 guard let self else { return }
 if ids.contains(self.active.id) {
     if self.isRunning { self.stop() }
     self.replaceWithNewConversation()
 }
 self.conversations.removeAll { ids.contains($0.id) }
 self.onChange?(.conversationList)
 }
 }
 }
 deinit { if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) } }

 // MARK: - Queries

 var isRunning: Bool { return active.phase.isActive }

 func refreshTerminals(keepActiveConversation: String? = nil) {
 // A running turn keeps its frozen target even when the live list changes.
 terminals = terminalLister?.listAgentTerminalSessions() ?? []
 // A turn that is mid-flight owns its conversation. Refreshing the terminal list
 // must not fold it into a different chat, otherwise the tool card and its result
 // are written to a conversation the user is not looking at.
 if let keepActiveConversation, active.id == keepActiveConversation {
 return
 }
 syncActiveTerminal()
 }

 private var probingModels = Set<String>()

 func discoverSelectedModelIfNeeded() {
 guard let selected = active.modelSelection,
       let choice = availableModels.first(where: { $0.modelID == selected.modelID && $0.providerID == selected.providerID }),
       choice.supportedEfforts == nil || choice.supportsImages == nil,
       let resolved = try? providerResolver.resolve(selection: choice),
       DefaultAIModelCatalogLoader.cachedReasoning(resolved.provider, choice.modelID) == nil else { return }
 let key = choice.providerID + "/" + choice.modelID
 guard probingModels.insert(key).inserted else { return }
 Task { [weak self] in
 _ = await Task.detached(priority: .utility) {
 try? DefaultAIModelCatalogLoader().discoverReasoning(for: resolved.provider, modelID: choice.modelID, apiKey: resolved.apiKey)
 }.value
 self?.probingModels.remove(key)
 self?.refreshModels()
 }
 }

 func refreshModels() {
 let choices = providerResolver.modelChoices()
 availableModels = choices
 if let current = active.modelSelection {
 if var choice = choices.first(where: { $0.providerID == current.providerID && $0.modelID == current.modelID }) {
 choice.reasoningEffort = current.reasoningEffort
 active.modelSelection = choice
 } else {
 if let fallback = providerResolver.defaultSelection() {
 active.modelSelection = fallback
 }
 }
 }
 onChange?(.composer)
 }

 // MARK: - Conversation lifecycle

 func startNewConversation() {
 guard !isRunning else { return }
 flushActive()
 replaceWithNewConversation()
 }

 private func replaceWithNewConversation() {
 resetEnhancement()
 let current = terminals.first(where: { $0.isCurrent })
 var fresh = AgentConversation(isDraft: true, boundRuntimeID: current?.runtimeID,
 boundConnectionGeneration: current?.connectionGeneration ?? 0)
 fresh.savedSessionID = current?.savedSessionID
 fresh.modelSelection = active.modelSelection ?? providerResolver.defaultSelection()
 fresh.permissionMode = active.permissionMode == .dangerFullAccess ? .supervised : active.permissionMode
 active = fresh
 restoreWireHistory()
 onChange?(.conversationList)
 onChange?(.transcript)
 onChange?(.composer)
 }

 /// Keeps one conversation per terminal. When the current terminal changes, the
 /// panel switches to that terminal's conversation instead of retargeting the
 /// existing one, so a draft or an in-flight question never jumps terminals.
 func syncActiveTerminal() {
 guard !isRunning else { return }
 let current = terminals.first(where: { $0.isCurrent })
 let runtimeID = current?.runtimeID
 let generation = current?.connectionGeneration ?? 0
 guard active.boundRuntimeID != runtimeID else {
 if let key = current?.savedSessionID, active.savedSessionID != key { active.savedSessionID = key; store.save(active, immediately: true); upsertIntoList() }
 if active.boundConnectionGeneration != generation {
 active.boundConnectionGeneration = generation
 }
 return
 }
 resetEnhancement()
 flushActive()
 if let runtimeID,
 let existing = conversations.first(where: { $0.boundRuntimeID == runtimeID }) ?? conversations.filter({ current?.savedSessionID != nil && $0.savedSessionID == current?.savedSessionID }).max(by: { $0.updatedAt < $1.updatedAt }) {
 active = existing
 active.boundRuntimeID = runtimeID
 active.savedSessionID = current?.savedSessionID ?? existing.savedSessionID
 active.boundConnectionGeneration = generation
 } else {
 var fresh = AgentConversation(
 isDraft: true,
 boundRuntimeID: runtimeID,
 boundConnectionGeneration: generation)
 fresh.savedSessionID = current?.savedSessionID
 fresh.modelSelection = active.modelSelection ?? providerResolver.defaultSelection()
 fresh.permissionMode = active.permissionMode == .dangerFullAccess ? .supervised : active.permissionMode
 active = fresh
 // Register the conversation against this terminal so switching back finds it;
 // flushActive() skips empty drafts and would otherwise never list it.
 if let runtimeID,
 conversations.contains(where: { $0.id == fresh.id }) == false {
 fresh.boundRuntimeID = runtimeID
 conversations.insert(fresh, at:0)
 }
 }
 restoreWireHistory()
 onChange?(.conversationList)
 onChange?(.transcript)
 onChange?(.composer)
 }

 /// The conversation belonging to the current terminal, if it exists.
 var activeTerminalRuntimeID: String? { active.boundRuntimeID }

 var activeTerminalTitle: String? {
 if isRunning, let turnTarget { return turnTarget.title }
 return terminals.first { $0.runtimeID == active.boundRuntimeID }?.title
 }

	/// Switches the panel to the conversation belonging to `runtimeID`, creating
	/// and binding one when that terminal has no chat yet. Refuses while a turn is
	/// running so an in-flight question cannot be moved to another terminal.
	func selectTerminal(runtimeID: String) {
		if active.boundRuntimeID == runtimeID { return }
		if isRunning { return }
		resetEnhancement()
		flushActive()
		if let existing = conversations.first(where: { $0.boundRuntimeID == runtimeID }) {
			active = existing
		} else {
			var fresh = AgentConversation(
				isDraft: true,
				boundRuntimeID: runtimeID,
				boundConnectionGeneration:
					terminals.first(where: { $0.runtimeID == runtimeID })?.connectionGeneration ?? 0)
			fresh.modelSelection = providerResolver.defaultSelection()
			fresh.permissionMode = active.permissionMode == .dangerFullAccess ? .supervised : active.permissionMode
			active = fresh
			conversations.insert(fresh, at:0)
		}
		restoreWireHistory()
		onChange?(.conversationList)
		onChange?(.transcript)
		onChange?(.composer)
	}
 func select(_ conversation: AgentConversation) {
 if isRunning || conversation.id == active.id { return }
 resetEnhancement()
 flushActive()
 active = conversation
 restoreWireHistory()
 onChange?(.conversationList)
 onChange?(.transcript)
 onChange?(.composer)
 }

 func delete(_ conversationID: String) {
 if active.id == conversationID, active.phase.isActive {
 stop()
 }
 store.delete(id: conversationID)
 conversations.removeAll { $0.id == conversationID }
 if active.id == conversationID {
 replaceWithNewConversation()
 return
 }
 onChange?(.conversationList)
 }

 func rename(_ conversationID: String, to title: String) {
 let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
 if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
 conversations[index].title = trimmed
 store.save(conversations[index], immediately: true)
 }
 if active.id == conversationID {
 active.title = trimmed
 }
 onChange?(.conversationList)
 }

 func flushActive() {
 if active.isDraft, active.items.isEmpty, active.draftText.isEmpty {
 return
 }
 active.isDraft = false
 store.save(active, immediately: true)
 upsertIntoList()
 }

 // MARK: - Composer

 func updateDraft(_ text: String) {
 if active.draftText == text { return }
 resetEnhancement()
 active.draftText = text
 store.save(active)
 onChange?(.composer)
 }

 func setModel(_ selection: AgentModelSelection) {
 active.modelSelection = selection
 store.save(active, immediately: true)
 upsertIntoList()
 onChange?(.composer)
 }

 func setPermissionMode(_ mode: AgentPermissionMode) {
 guard !isRunning else { return }
 active.permissionMode = mode
 store.save(active, immediately: true)
 upsertIntoList()
 onChange?(.composer)
 }

 func addContextChip(_ chip: AgentContextChip) {
 if active.draftChips.contains(where: { $0.uri == chip.uri }) { return }
 active.draftChips.append(chip)
 store.save(active)
 onChange?(.composer)
 }

 var onAttachmentError: ((String) -> Void)?
 func attachImage(_ data: Data) {
 let numbers = active.draftChips.compactMap { $0.imageNumber }
 guard numbers.count < 4 else { onAttachmentError?("每条消息最多可添加四张图片。"); return }
 do {
 let directory = store.rootDirectory.appendingPathComponent("images").appendingPathComponent(active.id)
 let next = max(numbers.max() ?? 0, active.lastDraftImageNumber ?? 0) + 1
 let chip = try AgentImages.save(data, in: directory, number: next)
 active.lastDraftImageNumber = next
 addContextChip(chip)
 } catch { onAttachmentError?("无法读取或保存图片。") }
 }

 func removeContextChip(_ id: String) {
 if let url = active.draftChips.first(where: { $0.id == id })?.imageFile { try? FileManager.default.removeItem(at: url) }
 active.draftChips.removeAll { $0.id == id }
 store.save(active)
 onChange?(.composer)
 }

 // MARK: - Send

 func send() {
 if isRunning { return }
 let text = active.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
 let chips = active.draftChips
 if text.isEmpty && chips.isEmpty { return }
 let images = chips.filter { $0.imageNumber != nil }
 if !images.isEmpty, let selected = active.modelSelection,
 availableModels.first(where: { $0.providerID == selected.providerID && $0.modelID == selected.modelID })?.supportsImages == false {
 onAttachmentError?("当前模型不支持图片输入。请选择支持图片的模型后发送。")
 return
 }
 let prompt = Self.promptText(text: text, chips: chips.filter { $0.imageNumber == nil })
 let content: Any
 do { content = try AgentImages.content(text: prompt, images: images) }
 catch { onAttachmentError?("无法读取附件，请移除后重新添加。"); return }
 resetEnhancement()

 turnToolCount = 0
 turnSettings = Self.settings()
 turnPreferences = AppSettingsStore.shared.snapshot()
 turnTarget = terminals.first(where: { $0.runtimeID == active.boundRuntimeID }).map {
 AgentTerminalExecutor.Target(runtimeID: $0.runtimeID, connectionGeneration: $0.connectionGeneration, title: $0.title)
 }
 terminalWaitDuration = 0
 turnTiming = AgentTurnTiming(sendAt: AgentClock.now())
 var item = AgentItem(kind: .user, text: text.isEmpty ? images.map { $0.label }.joined(separator: "、") : text)
 item.images = images.isEmpty ? nil : images
 if active.isDraft {
 active.isDraft = false
 if turnSettings?.localAutoTitleEnabled != false { active.title = AgentSession.derivedTitle(from: text) }
 }
 active.items.append(item)
 active.draftText = ""
 active.draftChips = []
 active.lastDraftImageNumber = nil
 active.phase = .preparing
 active.updatedAt = Date()
 store.save(active, immediately: true)
 upsertIntoList()
 onChange?(.transcript)
 onChange?(.composer)
 onChange?(.conversationList)

 wireMessages.append(["role": "user", "content": content])
 startTurn()
 }

 /// Builds the user message from typed text plus structured context. Referenced
 /// resources carry their URI and any frozen inline body, so a later terminal
 /// switch cannot rewrite what was already sent.
 static func promptText(text: String, chips: [AgentContextChip]) -> String {
 if chips.isEmpty { return text }
 var sections: [String] = []
 if text.isEmpty == false { sections.append(text) }
 for chip in chips {
 var line = "- \(chip.kind.rawValue)：\(chip.label) [\(chip.uri)]"
 if let detail = chip.detail, detail.isEmpty == false {
 line += "范围：\(detail)"
 }
 if let payload = chip.payload, payload.isEmpty == false {
 line += "\n```\n\(payload)\n```"
 } else {
 line += "（仅引用，需要时请用工具读取）"
 }
 sections.append(line)
 }
 return sections.joined(separator: "\n\n")
 }

 static func derivedTitle(from text: String) -> String {
 let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
 let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
 if trimmed.count > 28 {
 return String(trimmed.prefix(28))
 }
 return trimmed
 }

 // MARK: - Testing seam

 /// Runs one tool call through the same path the model uses, so a test can cover
 /// the permission decision, the approval hand-off and the executor without a
 /// network round trip.
 var lastToolTestError: String?

 func runToolForTesting(name: String, arguments: String, permission: AgentPermissionMode, repeating: Bool = false, followUpArguments: String? = nil) async -> Bool {
 commandsThatMustNotBeRetried.removeAll()
 active.permissionMode = permission
 // The executor resolves through the same list the UI shows, so seed it with the
 // stubbed target before running the call.
 terminals = [AgentTerminalSessionSummary(
 runtimeID: "t1",
 connectionGeneration:0,
 title: "test",
 kind: "local",
 environment: "",
 isCurrent: true,
 currentDirectory: nil,
 subtitle: nil)]
 turnTarget = AgentTerminalExecutor.Target(runtimeID: "t1", connectionGeneration: 1, title: "test")
 let call = AgentModelClient.ToolCallAccumulator(id: "call_test", name: name, arguments: arguments)
 var calls = [call]
 if repeating {
 var duplicate = call
 duplicate.id = "call_duplicate"
 calls.append(duplicate)
 }
 if let followUpArguments {
 calls.append(.init(id: "call_followup", name: name, arguments: followUpArguments))
 }
 let before = active.items.count
 do {
 try await handleToolCalls(calls, turnIndex:0, conversationID: active.id)
 } catch {
 lastToolTestError = String(describing: error)
 return false
 }
 return active.items.count > before
 }

 // MARK: - Turn loop

 private func startTurn() {
 inFlightTurn = nil
 commandsThatMustNotBeRetried.removeAll()
 let conversationID = active.id
 let turn = Task { [weak self] in
 guard let self else { return }
 do {
 try await self.requestModel(turnIndex:0, conversationID: conversationID)
 } catch is CancellationError {
 return
 } catch {
 guard !Task.isCancelled else { return }
 self.failTurn(error)
 }
 }
 inFlightTurn = turn
 }

 private var remainingTurnTime: TimeInterval {
 let elapsed = turnTiming.sendAt.map { AgentClock.now() - $0 } ?? 0
 return Double(turnSettings?.maxEffectiveMinutes ?? 30) * 60 - elapsed + terminalWaitDuration
 }

 private func checkTurnDeadline() throws {
 if remainingTurnTime <= 0 {
 throw AgentRunError.transport("本轮已达到设置中的执行时长上限。")
 }
 }

 private func requestModel(turnIndex: Int, conversationID: String, summarizeOnly: Bool = false, retryProtocol: Bool = false) async throws {
 try checkTurnDeadline()
 let invocationLimit = max(1, turnSettings?.maxModelInvocations ?? 40)
 guard turnIndex < invocationLimit else { throw AgentRunError.transport("已达到设置中的模型调用次数上限。") }
 let finishWithSummary = summarizeOnly || (invocationLimit > 1 && turnIndex == invocationLimit - 1)
 if Task.isCancelled { throw CancellationError() }

 var resolved: AgentProviderResolver.Resolved
 do {
 resolved = try providerResolver.resolve(selection: active.modelSelection)
 } catch let failure as AgentProviderResolver.Failure {
 throw AgentRunError.transport(failure.description)
 }

 active.phase = turnIndex == 0 ? .modelRequesting : .toolResultReporting
 onChange?(.phase)

 let placeholderID = UUID().uuidString
 let cached = DefaultAIModelCatalogLoader.cachedReasoning(resolved.provider, resolved.model.id)
 let supportedEfforts = resolved.model.capabilities.supportedReasoningEfforts ?? cached?.supportedReasoningEfforts
 turnContextLimit = resolved.model.capabilities.effectiveContextCharacterLimit
 var messages = buildWireMessages(summarizeOnly: finishWithSummary)
 if retryProtocol {
 messages.append(["role": "system", "content": "上一条回复没有可用正文或结构化工具调用，未执行任何操作。继续当前任务；需要工具时使用接口的 tool_calls，禁止在正文输出 DSML。工具不可用时说明实际进度和阻塞原因。 "])
 }
 let request = AgentModelClient.Request(
 baseURL: resolved.baseURL,
 apiKey: resolved.apiKey,
 modelID: resolved.model.id,
 messages: messages,
 tools: finishWithSummary ? [] : AgentToolCatalog.toolSchemas,
 temperature: nil,
 maxTokens: nil,
 reasoningEffort: active.modelSelection?.reasoningEffort.flatMap { effort in
 supportedEfforts?.contains(where: { $0.rawValue == effort }) == true ? effort : nil
 },
 thinkingCapability: resolved.model.capabilities.supportsThinking ?? cached?.supportsThinking,
 timeout: TimeInterval(resolved.provider.requestTimeoutSeconds)
 )

 var placeholder = AgentItem(id: placeholderID, kind: .assistant, isStreaming: true)
 placeholder.thinkingRequested = request.requestsThinking
 active.items.append(placeholder)
 let itemIndex = active.items.count - 1
 onChange?(.transcript)
 toolCallBuffer = [:]

 var visibleStream = AgentVisibleResponse()
 let itemID = placeholderID
 let result: Result<[AgentModelClient.ToolCallAccumulator], Error> = await withCheckedContinuation { continuation in
 turnTiming.requestAt = AgentClock.now()
 modelClient.stream(request, onEvent: { [weak self] event in
 guard let self else { return }
 guard self.active.id == conversationID,
 self.active.items.indices.contains(itemIndex),
 self.active.items[itemIndex].id == itemID,
 self.active.items[itemIndex].isStreaming else { return }
 switch event {
 case .firstByte:
 if self.turnTiming.firstByteAt == nil {
 self.turnTiming.firstByteAt = AgentClock.now()
 }
 case .textDelta(let fragment):
 let delta = visibleStream.append(fragment)
 guard !delta.isEmpty else { return }
 if self.turnTiming.firstVisibleTextAt == nil {
 self.turnTiming.firstVisibleTextAt = AgentClock.now()
 }
 if self.active.phase != .answering {
 self.active.phase = .answering
 self.onChange?(.phase)
 }
 if itemIndex < self.active.items.count {
 self.active.items[itemIndex].text += delta
 }
 self.onChange?(.streaming(itemID: itemID))
 case .reasoningDelta(let delta):
 if self.active.phase != .thinking {
 self.active.phase = .thinking
 self.onChange?(.phase)
 }
 if itemIndex < self.active.items.count {
 self.active.items[itemIndex].reasoning += delta
 }
 self.onChange?(.streaming(itemID: itemID))
 case .toolCall(let index, let id, let name, let delta):
 var call = self.toolCallBuffer[index] ?? AgentModelClient.ToolCallAccumulator()
 if let id, id.isEmpty == false { call.id = id }
 if let name, name.isEmpty == false { call.name = name }
 call.arguments += delta
 self.toolCallBuffer[index] = call
 }
 }, onCompletion: { completion in
 continuation.resume(returning: completion)
 })
 }

 try Task.checkCancellation()
 active.items[itemIndex].text += visibleStream.finish()
 let responseReasoning = active.items[itemIndex].reasoning
 let responseText = active.items[itemIndex].text
 if itemIndex < active.items.count {
 active.items[itemIndex].isStreaming = false
 let isEmpty = active.items[itemIndex].text.isEmpty && active.items[itemIndex].reasoning.isEmpty
 if isEmpty {
 active.items.remove(at: itemIndex)
 }
 }
 onChange?(.transcript)

 let calls: [AgentModelClient.ToolCallAccumulator]
 switch result {
 case .failure(let error):
 throw error
 case .success(let payload):
 if payload.isEmpty {
 calls = toolCallBuffer.keys.sorted().compactMap { toolCallBuffer[$0] }
 } else {
 calls = payload
 }
 }

 if Task.isCancelled { throw CancellationError() }
 try Self.validateSummaryResponse(summaryOnly: finishWithSummary, hasToolCalls: !calls.isEmpty)
 if calls.isEmpty && (visibleStream.sawProtocol || responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
 if turnIndex + 1 < invocationLimit {
 try await requestModel(turnIndex: turnIndex + 1, conversationID: conversationID, summarizeOnly: finishWithSummary, retryProtocol: true)
 return
 }
 throw AgentRunError.transport("模型调用次数已达本轮上限，最后一次回复没有可用内容。任务完成情况尚未确认。")
 }
 if calls.isEmpty || finishWithSummary {
 if !responseText.isEmpty {
 wireMessages.append(["role": "assistant", "content": responseText])
 }
 active.phase = .completed
 finishTurn()
 return
 }
 try await handleToolCalls(calls, turnIndex: turnIndex, conversationID: conversationID, responseText: responseText, reasoning: responseReasoning)
 }

 static func validateSummaryResponse(summaryOnly: Bool, hasToolCalls: Bool) throws {
 guard !summaryOnly || !hasToolCalls else {
 throw AgentRunError.transport("模型在总结阶段仍请求执行工具。该步骤未执行，任务完成情况尚未确认。")
 }
 }

 private func handleToolCalls(_ calls: [AgentModelClient.ToolCallAccumulator], turnIndex: Int, conversationID: String, responseText: String = "", reasoning: String = "") async throws {
 var assistantMessage: [String: Any] = ["role": "assistant", "content": NSNull()]
 if !reasoning.isEmpty { assistantMessage["reasoning_content"] = reasoning }
 if !responseText.isEmpty {
 assistantMessage["content"] = responseText
 }
 var wireCalls: [[String: Any]] = []
 for (position, call) in calls.enumerated() {
 let callID = call.id.isEmpty ? "call_\(position)" : call.id
 wireCalls.append([
 "id": callID,
 "type": "function",
 "function": ["name": call.name, "arguments": call.arguments]
 ])
 }
 assistantMessage["tool_calls"] = wireCalls
 wireMessages.append(assistantMessage)

 var finishWithSummary = false
 for (position, call) in calls.enumerated() {
 try checkTurnDeadline()
 if Task.isCancelled { throw CancellationError() }
 let callID = call.id.isEmpty ? "call_\(position)" : call.id
 let definition = AgentToolCatalog.definition(named: call.name)
 let title = definition?.title ?? call.name
 let command: String?
 switch call.name {
 case AgentToolCatalog.configurationWrite: command = AgentConfigurationWrite.command(arguments: call.arguments)
 case AgentToolCatalog.configurationPrepare: command = AgentConfigurationWrite.prepare(arguments: call.arguments)
 default: command = AgentToolCatalog.command(fromArguments: call.arguments)
 }
 var invocation = AgentToolInvocation(
 id: callID,
 name: call.name,
 title: title,
 argumentsJSON: call.arguments,
 command: command
 )

 invocation.recordingScope = turnSettings?.terminalRecordingScope ?? "bounded"
 turnToolCount += 1
 if turnToolCount > (turnSettings?.maxToolSteps ?? 40) { finishWithSummary = true }
 if finishWithSummary {
 let message = "本轮已停止，未执行。请根据已获取的输出答复用户。"
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: message))
 continue
 }

 if definition == nil {
 let message = "未知工具：\(call.name)"
 appendToolResult(invocation: invocation, output: message, status: .failure)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: message))
 continue
 }

 if call.name == AgentToolCatalog.listTerminals {
 refreshTerminals(keepActiveConversation: conversationID)
 var lines: [String] = []
 for terminal in terminals {
 lines.append("\(terminal.runtimeID)\t\(terminal.title)\t\(terminal.currentDirectory ?? "")")
 }
 let body = lines.isEmpty ? "没有可用的终端会话" : lines.joined(separator: "\n")
 appendToolResult(invocation: invocation, output: body, status: .success)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: body))
 continue
 }

 if call.name == AgentToolCatalog.getTerminalOutput {
 let requestedID = AgentToolCatalog.terminalID(fromArguments: call.arguments)
 if let target = Self.resolveTurnTarget(turnTarget, requestedID: requestedID),
 let pane = try? executor.resolver.resolveTerminalTarget(.runtimeID(target.runtimeID)),
 pane.isAgentRuntimeConnected, pane.agentRuntimeGeneration == target.connectionGeneration {
 invocation.terminalTitle = target.title
 let body = terminalContext(pane.agentTerminalOutputTranscript)
 appendToolResult(invocation: invocation, output: body, status: .success)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: body))
 } else {
 let message = "没有可读取的终端会话"
 appendToolResult(invocation: invocation, output: message, status: .failure)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: message))
 }
 continue
 }

 let requestedID = AgentToolCatalog.terminalID(fromArguments: call.arguments)
 guard let target = Self.resolveTurnTarget(turnTarget, requestedID: requestedID) else {
 let message = "工具目标与本轮绑定的终端不一致。请选择目标终端后重新发送。"
 appendToolResult(invocation: invocation, output: message, status: .failure)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: message))
 continue
 }
 invocation.terminalTitle = target.title
 invocation.runtimeID = target.runtimeID
 invocation.connectionGeneration = target.connectionGeneration
 if let command = invocation.command, commandsThatMustNotBeRetried.contains(command) {
 let message = "已阻止重复执行。请根据上一条命令的实际报错修正参数，或换用其他检查方式继续任务。"
 appendToolResult(invocation: invocation, output: message, status: .rejected)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: message))
 continue
 }
 guard let pane = try? executor.resolver.resolveTerminalTarget(.runtimeID(target.runtimeID)),
 pane.isAgentRuntimeConnected, pane.agentRuntimeGeneration == target.connectionGeneration else {
 let message = "目标终端已断开或重新连接，请重新发起请求。"
 appendToolResult(invocation: invocation, output: message, status: .failure)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: message))
 continue
 }
 if call.name == AgentToolCatalog.terminalCommand, let command = invocation.command,
    AgentConfigurationWrite.requiresStaging(command) {
 let reason = "写入配置请先调用 prepare_configuration_file，编辑返回的 draft，再调用 install_configuration_file。该工具会备份已有文件，目标不存在时直接创建。"
 appendToolResult(invocation: invocation, output: reason, status: .rejected)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: reason))
 continue
 }
 let decision = AgentPermissionPolicy.decide(invocation: invocation, mode: active.permissionMode, automation: pane.agentAutomationPolicy, preferences: turnPreferences)
 switch decision {
 case .allow:
 try await execute(invocation: invocation, callID: callID, target: target)
 case .deny(let reason):
 appendToolResult(invocation: invocation, output: reason, status: .rejected)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: "调用被拒绝：\(reason)"))
 case .ask(var request):
 request.targetTitle = target.title
 request.commandPurpose = AgentToolCatalog.commandPurpose(fromArguments: call.arguments)
 invocation.status = .awaitingApproval
 active.items.append(AgentItem(kind: .tool, tool: invocation))
 onChange?(.transcript)
 let grant = try await requestApproval(request)
 try Task.checkCancellation()
 if grant != nil {
 try await execute(invocation: invocation, callID: callID, target: target)
 } else {
 appendToolResult(invocation: invocation, output: "用户拒绝了本次执行", status: .rejected)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: "用户拒绝了本次执行"))
 }
 }
 }

 if Task.isCancelled { throw CancellationError() }
 try await requestModel(turnIndex: turnIndex + 1, conversationID: conversationID, summarizeOnly: finishWithSummary)
 }

 private func execute(invocation: AgentToolInvocation, callID: String, target: AgentTerminalExecutor.Target) async throws {
 try Task.checkCancellation()
 var tool = invocation
 tool.status = .running
 tool.startedAt = Date()
 var item = AgentItem(kind: .tool, tool: tool)
 if let index = active.items.lastIndex(where: { $0.tool?.id == callID && $0.tool?.status == .awaitingApproval }) {
 item.id = active.items[index].id
 active.items[index] = item
 } else {
 active.items.append(item)
 }
 let itemID = item.id
 active.phase = .toolExecuting
 onChange?(.transcript)
 onChange?(.phase)

 guard let command = tool.command else {
 appendToolResult(invocation: tool, output: "该工具缺少必需参数", status: .failure)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: "该工具缺少必需参数"))
 return
 }
 if turnTiming.toolRequestedAt == nil {
 turnTiming.toolRequestedAt = AgentClock.now()
 }
 try checkTurnDeadline()
 let waitStarted = AgentClock.now()
 let result = await executor.execute(command: command, on: target, timeout: .infinity, onOutput: { [weak self] output in
 guard let self, let index = self.active.items.indices.last,
 self.active.items[index].id == itemID, self.active.items[index].tool?.status == .running else { return }
 self.active.items[index].tool?.output = output
 self.onChange?(.streaming(itemID: itemID))
 }, onStart: { [weak self] in
 self?.turnTiming.toolStartedAt = AgentClock.now()
 })
 try Task.checkCancellation()
 terminalWaitDuration += AgentClock.now() - waitStarted
 turnTiming.toolFinishedAt = AgentClock.now()

 if [AgentToolCatalog.configurationPrepare, AgentToolCatalog.configurationWrite].contains(tool.name) {
 let receipt = AgentConfigurationWrite.receipt(arguments: tool.argumentsJSON, output: result.output)
 let expectedStatuses = tool.name == AgentToolCatalog.configurationPrepare ? ["prepared"] : ["created", "written"]
 let success = !result.wasCancelled && result.errorMessage == nil && (result.exitCode ?? 0) == 0 && expectedStatuses.contains(receipt["status"] ?? "")
 let json = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .withoutEscapingSlashes])
 let metadata = String(decoding: json, as: UTF8.self)
 let failure = receipt["status"] == "conflict" ? "原配置已变化，请重新读取并生成草稿。" : "未确认操作成功，请检查终端状态。"
 if !success { commandsThatMustNotBeRetried.insert(command) }
 appendToolResult(invocation: tool, output: result.output, status: success ? .success : (result.wasCancelled ? .cancelled : .failure), error: success ? nil : failure, exitCode: result.exitCode, completion: result.completion)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: (success ? "" : failure + "\n") + metadata + "\n" + terminalContext(result.output)))
 return
 }
 let modelOutput = terminalContext(result.output)
 if result.completion != .confirmed || result.errorMessage != nil || result.exitCode != 0 {
 commandsThatMustNotBeRetried.insert(command)
 }
 if let error = result.errorMessage {
 let failed = result.wasCancelled ? AgentToolStatus.cancelled : .failure
 appendToolResult(invocation: tool, output: result.output, status: failed, error: error, completion: result.completion)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: "\(error)\n\(modelOutput)"))
 return
 }
 if let exitCode = result.exitCode, exitCode != 0 {
 appendToolResult(invocation: tool, output: result.output, status: .failure, error: "命令退出码：\(exitCode)", exitCode: exitCode, completion: .confirmed)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: "命令退出码：\(exitCode)\n\(modelOutput)"))
 return
 }
 if result.exitCode == nil, let diagnostic = Self.shellFailureDiagnostic(command: command, output: result.output) {
 appendToolResult(invocation: tool, output: result.output, status: .failure, error: diagnostic, completion: result.completion)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: "\(diagnostic)\n\(modelOutput)"))
 return
 }
 if result.completion == .confirmed {
 let body = result.output.isEmpty ? "无输出内容" : modelOutput
 appendToolResult(invocation: tool, output: result.output, status: .success, exitCode: result.exitCode, completion: .confirmed)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: body))
 return
 }
 let body = "终端已返回，未报告退出码。以下是本次命令的实际输出；若其中已有回答所需指标，直接作答，无需再读取终端或重复采样。\n\(modelOutput)"
 appendToolResult(invocation: tool, output: result.output, status: .success, completion: .unknown)
 wireMessages.append(AgentSession.toolMessage(callID: callID, content: body))
 }

 static func shellFailureDiagnostic(command: String, output: String) -> String? {
 guard let executable = command.split(whereSeparator: \.isWhitespace).first,
       executable.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-./".contains($0)) }),
       let firstLine = output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces) else { return nil }
 if firstLine == "\(executable): command not found" || firstLine.hasSuffix(": \(executable): command not found")
    || firstLine.hasSuffix(": command not found: \(executable)") {
 return "终端报告找不到命令，未取得退出码。"
 }
 let program = executable.split(separator: "/").last ?? executable
 if program == "curl", firstLine.hasPrefix("curl: "), !command.contains("--help") {
 return "curl 报告错误，请根据输出修正参数或处理连接故障。"
 }
 if program == "mpstat", firstLine.hasPrefix("Usage: mpstat "), !command.contains("--help") {
 return "终端返回了用法说明，未取得退出码。请核对参数，勿原样重试。"
 }
 return nil
 }

 private func appendToolResult(invocation: AgentToolInvocation, output: String, status: AgentToolStatus, error: String? = nil, exitCode: Int? = nil, completion: AgentCompletionState? = nil) {
 if let index = active.items.lastIndex(where: { $0.tool?.id == invocation.id && ($0.tool?.status == .running || $0.tool?.status == .awaitingApproval) }) {
 active.items[index].tool?.status = status
 active.items[index].tool?.output = output
 active.items[index].tool?.errorMessage = error
 active.items[index].tool?.exitCode = exitCode
 active.items[index].tool?.completionState = completion
 active.items[index].tool?.finishedAt = Date()
 } else {
 var tool = invocation
 tool.status = status
 tool.output = output
 tool.errorMessage = error
 tool.exitCode = exitCode
 tool.completionState = completion
 tool.finishedAt = Date()
 active.items.append(AgentItem(kind: .tool, tool: tool))
 }
 active.phase = .toolResultReporting
 onChange?(.transcript)
 onChange?(.phase)
 }

 private func terminalContext(_ text: String) -> String {
 let output = AIAssistantCoordinator.agentTerminalContext(text, limit: turnContextLimit, mode: turnSettings?.terminalOutputMode ?? "boundedHeadTail", compress: turnSettings?.automaticContextCompressionEnabled ?? true)
 return output.isEmpty ? "当前没有可提供的终端输出。" : output
 }

 private static func toolMessage(callID: String, content: String) -> [String: Any] {
 return ["role": "tool", "tool_call_id": callID, "content": content]
 }

 // MARK: - Approval

	private func requestApproval(_ request: AgentApprovalRequest) async throws -> AgentApprovalGrant? {
		if Task.isCancelled { throw CancellationError() }
		// A card the user walks away from must not pin the session in waitingApproval
		// forever, so the wait is bounded and then treated as a rejection.
		let waitSeconds = turnSettings.map { TimeInterval($0.approvalDeadlineMinutes * 60) } ?? approvalTimeoutSeconds
		let timeoutTask = Task { [weak self] in
			try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
			guard Task.isCancelled == false else { return }
			await MainActor.run { self?.expirePendingApproval() }
		}
		defer { timeoutTask.cancel() }
		return try await withCheckedThrowingContinuation { continuation in
			self.approvalContinuation = continuation
			let resumeHook = continuation
			_ = resumeHook
			self.pendingApproval = request
			self.active.phase = .waitingApproval
			self.onChange?(.approval)
			self.onChange?(.phase)
		}
	}

	/// Called when nobody answered in time, so the turn ends instead of pinning the
	/// composer in waitingApproval.
	private func expirePendingApproval() {
		guard pendingApproval != nil else { return }
		rejectPending()
	}

 func approvePending(_ grant: AgentApprovalGrant) {
 guard pendingApproval != nil else { return }
 pendingApproval = nil
 // Resume before notifying the UI: the notification repaints the card and can
 // re-enter the session, which would clear approvalContinuation and leave the
 // awaiting request suspended forever.
 let continuation = approvalContinuation
 approvalContinuation = nil
 continuation?.resume(returning: grant)
 onChange?(.approval)
 }

 func rejectPending() {
 guard pendingApproval != nil else { return }
 pendingApproval = nil
 let continuation = approvalContinuation
 approvalContinuation = nil
 continuation?.resume(returning: nil)
 onChange?(.approval)
 }

 // MARK: - Stop

 /// Cancels model output, dismisses any approval, and cancels only this task's
 /// own execution.
 func stop() {
 if let turn = inFlightTurn {
 turn.cancel()
 inFlightTurn = nil
 }
 modelClient.cancel()
 let interruptSent = executor.hasActiveExecution ? executor.cancelActive() : nil
 if pendingApproval != nil {
 pendingApproval = nil
 // Resume first so the awaiting request unwinds before the UI updates.
 let continuation = approvalContinuation
 approvalContinuation = nil
 continuation?.resume(returning: nil)
 onChange?(.approval)
 }
 markInterrupted(interruptSent: interruptSent)
 }

 private func markInterrupted(interruptSent: Bool?) {
 if let index = active.items.lastIndex(where: { $0.kind == .assistant && $0.isStreaming }) {
 active.items[index].isStreaming = false
 active.items[index].aborted = true
 }
 for index in active.items.indices where active.items[index].tool?.status == .running || active.items[index].tool?.status == .awaitingApproval {
 active.items[index].tool?.status = .cancelled
 if interruptSent == false {
 active.items[index].tool?.errorMessage = "未能向终端发送中断信号，命令可能仍在运行。"
 }
 active.items[index].tool?.finishedAt = Date()
 }
 restoreWireHistory()
 active.phase = .interrupted
 active.updatedAt = Date()
 store.save(active, immediately: true)
 upsertIntoList()
 onChange?(.transcript)
 onChange?(.phase)
 onChange?(.conversationList)
 }

 private func failTurn(_ error: Error) {
 var message = error.localizedDescription
 if let localized = error as? LocalizedError {
 if let description = localized.errorDescription {
 message = description
 }
 }
 restoreWireHistory()
 active.phase = .failed
 active.items.append(AgentItem(kind: .error, text: message))
 active.updatedAt = Date()
 store.save(active, immediately: true)
 upsertIntoList()
 onChange?(.transcript)
 onChange?(.phase)
 onChange?(.conversationList)
 }

 private func finishTurn() {
 active.phase = .completed
 active.updatedAt = Date()
 store.save(active, immediately: true)
 upsertIntoList()
 onChange?(.transcript)
 onChange?(.phase)
 onChange?(.conversationList)
 }

 private func upsertIntoList() {
 if let index = conversations.firstIndex(where: { $0.id == active.id }) {
 conversations[index] = active
 } else {
 conversations.insert(active, at:0)
 }
 conversations.sort { $0.updatedAt > $1.updatedAt }
 }

 // MARK: - Wire messages

 private func restoreWireHistory() {
 wireMessages = active.items.compactMap { item in
 guard !item.aborted, !item.isStreaming, !item.text.isEmpty else { return nil }
 switch item.kind {
 case .user: return ["role": "user", "content": (try? AgentImages.content(text: item.text, images: item.images ?? [])) ?? (item.text + "（历史图片不可用）")]
 case .assistant: return ["role": "assistant", "content": item.text]
 default: return nil
 }
 }
 }

 private func buildWireMessages(summarizeOnly: Bool = false) -> [[String: Any]] {
 var messages: [[String: Any]] = []
 let targetContext = turnTarget.map { "本轮绑定终端 ID：\($0.runtimeID)。终端工具仅能读取或操作此终端。" }
 ?? "本轮未绑定终端。需要操作时，请用户先选择终端。"
 let summary = summarizeOnly ? "\n本轮终端操作已结束。直接用已有工具结果答复用户，区分已有结论与尚未取得的数据。" : ""
 messages.append(["role": "system", "content": AgentPrompt.systemPrompt + "\n" + targetContext + summary + "\n" + (turnSettings?.globalInstructions ?? "")])
 var history = wireMessages
 if history.count > 40,
 let boundary = history.indices.first(where: { $0 >= history.count - 40 && history[$0]["role"] as? String == "user" }) {
 history = Array(history[boundary...])
 }
 messages.append(contentsOf: history)
 return messages
 }

 // MARK: - Targeting

 /// The selected terminal and connection generation are frozen at send time.
 static func resolveTurnTarget(_ target: AgentTerminalExecutor.Target?, requestedID: String?) -> AgentTerminalExecutor.Target? {
 guard let target, requestedID == nil || requestedID == target.runtimeID else { return nil }
 return target
 }

 // MARK: - Prompt enhancement

 private var enhancementTask: Task<Void, Never>?
 private var enhancementOriginal: String?
 private(set) var enhancementState: AgentPromptEnhancementState = .idle

 func enhanceDraft() {
 if enhancementState == .loading {
 resetEnhancement()
 onChange?(.composer)
 return
 }
 if enhancementState == .undo, let original = enhancementOriginal {
 resetEnhancement()
 active.draftText = original
 store.save(active)
 onChange?(.composer)
 return
 }

 let original = active.draftText
 let input = original.trimmingCharacters(in: .whitespacesAndNewlines)
 guard !input.isEmpty else { return }
 let resolved: AgentProviderResolver.Resolved
 do {
 resolved = try providerResolver.resolveEnhancement(selection: active.modelSelection)
 } catch {
 enhancementState = .failed((error as? AgentProviderResolver.Failure)?.description ?? "请检查 AI 设置后重试。")
 onChange?(.composer)
 return
 }

 let enhancer = promptEnhancer
 enhancementState = .loading
 enhancementTask = Task { [weak self] in
 do {
 let rewritten = try await enhancer.rewrite(input, using: resolved)
 guard !Task.isCancelled, let self else { return }
 self.enhancementTask = nil
 self.enhancementOriginal = original
 self.enhancementState = .undo
 self.active.draftText = rewritten
 self.store.save(self.active)
 self.onChange?(.composer)
 } catch {
 guard !Task.isCancelled, let self else { return }
 self.enhancementTask = nil
 let message = (error as? AgentPromptEnhancer.Failure)?.errorDescription
 ?? "提示词增强失败，请检查模型连接后重试。"
 self.enhancementState = .failed(message)
 self.onChange?(.composer)
 }
 }
 onChange?(.composer)
 }

 private func resetEnhancement() {
 enhancementTask?.cancel()
 enhancementTask = nil
 enhancementOriginal = nil
 enhancementState = .idle
 }
}
