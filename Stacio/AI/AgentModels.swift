import Foundation

enum AgentPhase: String, Codable, Equatable {
 case idle
 case queued
 case preparing
 case modelRequesting
 case thinking
 case waitingApproval
 case waitingUserInput
 case toolExecuting
 case toolResultReporting
 case answering
 case reconnecting
 case completed
 case failed
 case interrupted

 static let active: Set<AgentPhase> = [
 .queued, .preparing, .modelRequesting, .thinking, .waitingApproval,
 .waitingUserInput, .toolExecuting, .toolResultReporting, .answering, .reconnecting
 ]

 var isActive: Bool { return AgentPhase.active.contains(self) }

 var caption: String {
 switch self {
 case .idle: return ""
 case .queued: return "准备开始…"
 case .preparing: return "正在准备任务"
 case .modelRequesting: return "等待模型响应"
 case .thinking: return "深度思考中..."
 case .waitingApproval: return "等待执行确认"
 case .waitingUserInput: return "等待用户输入"
 case .toolExecuting: return "正在执行工具"
 case .toolResultReporting: return "正在回传工具结果…"
 case .answering: return "正在回答中"
 case .reconnecting: return "连接中，正在恢复…"
 case .completed: return "任务已完成"
 case .failed: return "任务执行失败"
 case .interrupted: return "任务已中断"
 }
 }

 func stripCaption(toolTitle: String?) -> String {
 switch self {
 case .toolExecuting:
 if let toolTitle { return "正在\(toolTitle)" }
 return caption
 case .waitingApproval:
 if let toolTitle { return "等待\(toolTitle)确认" }
 return caption
 default:
 return caption
 }
 }
}

enum AgentItemKind: String, Codable {
 case user
 case assistant
 case tool
 case rejected
 case error
}

struct AgentItem: Identifiable, Codable, Equatable {
 var id: String
 var kind: AgentItemKind
 var text: String
 var reasoning: String
 var images: [AgentContextChip]?
 var thinkingRequested: Bool?
 var tool: AgentToolInvocation?
 var isStreaming: Bool
 var createdAt: Date
 var aborted: Bool

 init(id: String = UUID().uuidString, kind: AgentItemKind, text: String = "", reasoning: String = "", tool: AgentToolInvocation? = nil, isStreaming: Bool = false, createdAt: Date = Date(), aborted: Bool = false) {
 self.id = id
 self.kind = kind
 self.text = text
 self.reasoning = reasoning
 self.tool = tool
 self.isStreaming = isStreaming
 self.createdAt = createdAt
 self.aborted = aborted
 }
}

enum AgentToolStatus: String, Codable {
 case pending
 case awaitingApproval
 case running
 case success
 case failure
 case rejected
 case cancelled

 var label: String {
 switch self {
 case .pending: return "等待中"
 case .awaitingApproval: return "待审批"
 case .running: return "执行中"
 case .success: return "成功"
 case .failure: return "失败"
 case .rejected: return "已拒绝"
 case .cancelled: return "已取消"
 }
 }
}

enum AgentCompletionState: String, Codable {
 case confirmed
 case unknown
 case unconfirmed
}

struct AgentToolInvocation: Identifiable, Codable, Equatable {
 var id: String
 var name: String
 var title: String
 var argumentsJSON: String
 var terminalTitle: String?
 var command: String?
 var runtimeID: String?
 var connectionGeneration: UInt64
 var status: AgentToolStatus
 var output: String
 var exitCode: Int?
 var recordingScope: String?
 var completionState: AgentCompletionState?
 var errorMessage: String?
 var startedAt: Date?
 var finishedAt: Date?

 init(id: String, name: String, title: String, argumentsJSON: String, command: String? = nil, runtimeID: String? = nil, connectionGeneration: UInt64=0, status: AgentToolStatus = .pending, output: String = "", exitCode: Int? = nil, completionState: AgentCompletionState? = nil, errorMessage: String? = nil, startedAt: Date? = nil, finishedAt: Date? = nil) {
 self.id = id
 self.name = name
 self.title = title
 self.argumentsJSON = argumentsJSON
 self.command = command
 self.runtimeID = runtimeID
 self.connectionGeneration = connectionGeneration
 self.status = status
 self.output = output
 self.exitCode = exitCode
 self.completionState = completionState
 self.errorMessage = errorMessage
 self.startedAt = startedAt
 self.finishedAt = finishedAt
 }
}
enum AgentContextKind: String, Codable {
 case terminal
 case connection
 case file
 case folder
 case selection
}

struct AgentContextChip: Identifiable, Codable, Equatable {
 var id: String
 var kind: AgentContextKind
 var label: String
 var detail: String?
 var imageNumber: Int?
 var uri: String
 var payload: String?
 var runtimeID: String?
 var connectionGeneration: UInt64

 init(id: String = UUID().uuidString, kind: AgentContextKind, label: String, detail: String? = nil, uri: String, payload: String? = nil, runtimeID: String? = nil, connectionGeneration: UInt64=0) {
 self.id = id
 self.kind = kind
 self.label = label
 self.detail = detail
 self.uri = uri
 self.payload = payload
 self.runtimeID = runtimeID
 self.connectionGeneration = connectionGeneration
 }
}

enum AgentPermissionMode: String, Codable, CaseIterable {
 case supervised
 case smartApproval
 case dangerFullAccess

 var label: String {
 switch self {
 case .supervised: return L10n.Settings.requireEveryCommand
 case .smartApproval: return L10n.Settings.allowLowRisk
 case .dangerFullAccess: return L10n.Settings.allowAllCommands
 }
 }

 var shortDescription: String {
 switch self {
 case .supervised: return "每条终端命令都由你确认"
 case .smartApproval: return "自动执行已识别的只读命令和少量安全写入；其他命令需确认"
 case .dangerFullAccess: return "自动执行常用查询、软件包安装和服务管理；生产环境或高风险操作需确认"
 }
 }

 var isDangerous: Bool { self == .dangerFullAccess }
}

struct AgentApprovalRequest: Identifiable, Codable, Equatable {
 var id: String
 var toolID: String
 var toolTitle: String
 var targetTitle: String?
 var summary: String
 var commandPurpose: String?
 var reason: String?
 var isDangerous: Bool
 var createdAt: Date

 init(id: String = UUID().uuidString, toolID: String, toolTitle: String, summary: String, reason: String? = nil, isDangerous: Bool = false, createdAt: Date = Date()) {
 self.id = id
 self.toolID = toolID
 self.toolTitle = toolTitle
 self.summary = summary
 self.reason = reason
 self.isDangerous = isDangerous
 self.createdAt = createdAt
 }
}

enum AgentApprovalGrant {
 case once
}

struct AgentConversation: Identifiable, Codable, Equatable {
 var id: String
 var title: String
 var createdAt: Date
 var updatedAt: Date
 var items: [AgentItem]
 var phase: AgentPhase
 var draftText: String
 var draftChips: [AgentContextChip]
 var lastDraftImageNumber: Int?
 var permissionMode: AgentPermissionMode
 var modelSelection: AgentModelSelection?
 var isDraft: Bool
 /// The terminal this conversation belongs to. Each terminal keeps its own
 /// conversation, so switching terminals switches the chat rather than
 /// retargeting an existing one.
 var savedSessionID: String?
 var boundRuntimeID: String?
 var boundConnectionGeneration: UInt64

 init(id: String = UUID().uuidString, title: String = "", createdAt: Date = Date(), updatedAt: Date = Date(), items: [AgentItem] = [], phase: AgentPhase = .idle, draftText: String = "", draftChips: [AgentContextChip] = [], permissionMode: AgentPermissionMode = .supervised, modelSelection: AgentModelSelection? = nil, isDraft: Bool = false, boundRuntimeID: String? = nil, boundConnectionGeneration: UInt64 = 0) {
 self.id = id
 self.title = title
 self.createdAt = createdAt
 self.updatedAt = updatedAt
 self.items = items
 self.phase = phase
 self.draftText = draftText
 self.draftChips = draftChips
 self.permissionMode = permissionMode
 self.modelSelection = modelSelection
 self.isDraft = isDraft
 self.boundRuntimeID = boundRuntimeID
 self.boundConnectionGeneration = boundConnectionGeneration
 }

 var displayTitle: String {
 let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
 return trimmed.isEmpty ? "未命名会话" : trimmed
 }

 var isRunning: Bool { return phase.isActive }

 var hasPendingApproval: Bool {
 return items.contains { $0.tool?.status == .awaitingApproval }
 }
}

struct AgentModelSelection: Codable, Equatable {
 var providerID: String
 var providerName: String
 var modelID: String
 var modelDisplayName: String
 var supportedEfforts: [String]?
 var supportsImages: Bool?
 var supportsThinking: Bool?
 var reasoningEffort: String?

 init(providerID: String, providerName: String, modelID: String, modelDisplayName: String, reasoningEffort: String? = nil) {
 self.providerID = providerID
 self.providerName = providerName
 self.modelID = modelID
 self.modelDisplayName = modelDisplayName
 self.reasoningEffort = reasoningEffort
 }

 var effortLabel: String {
 if supportsThinking == false { return "不支持思考" }
 guard let reasoningEffort, supportedEfforts?.contains(reasoningEffort) == true else { return "模型默认" }
 return ["minimal": "最低", "low": "低", "medium": "中", "high": "高"][reasoningEffort] ?? reasoningEffort
 }
 var menuLabel: String { return modelDisplayName }
}

enum AgentRunError: LocalizedError, Equatable {
 case noProviderConfigured
 case missingCredential(String)
 case endpointRejected(String)
 case upstream(status: Int, message: String)
 case transport(String)
 case terminalUnavailable(String)
 case terminalDisconnected
 case cancelled

 var errorDescription: String? {
 switch self {
 case .noProviderConfigured:
 return "尚未配置可用的模型供应商，请先在「AI设置」中添加并启用模型。"
 case .missingCredential(let name):
 return "供应商「\(name)」缺少可用的 API凭据，请在「AI设置」中补充。"
 case .endpointRejected(let detail):
 return "模型服务地址不可用：\(detail)"
 case .upstream(let status, let message):
 return "模型请求失败（HTTP \(status)）：\(message)"
 case .transport(let message):
 return "模型请求中断：\(message)"
 case .terminalUnavailable(let runtimeID):
 return "指定的终端 \(runtimeID)未找到或未登录"
 case .terminalDisconnected:
 return "终端会话已断开，无法确认命令执行结果"
 case .cancelled:
 return "已停止生成"
 }
 }
}
