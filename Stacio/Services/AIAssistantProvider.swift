import Foundation

public struct AITerminalContext: Equatable, Sendable {
    public let runtimeID: String
    public let historyScopeID: String
    public let title: String
    public let currentDirectory: String?
    public let recentTranscript: String

    public init(
        runtimeID: String,
        historyScopeID: String? = nil,
        title: String,
        currentDirectory: String?,
        recentTranscript: String
    ) {
        self.runtimeID = runtimeID
        self.historyScopeID = historyScopeID ?? runtimeID
        self.title = title
        self.currentDirectory = currentDirectory
        self.recentTranscript = recentTranscript
    }
}

public struct AIAssistantRequest: Equatable, Sendable {
    public let question: String
    public let context: AITerminalContext
    public let conversationHistory: [AIAssistantConversationMessage]
    public let attachments: [AIAssistantAttachment]

    public init(
        question: String,
        context: AITerminalContext,
        conversationHistory: [AIAssistantConversationMessage] = [],
        attachments: [AIAssistantAttachment] = []
    ) {
        self.question = question
        self.context = context
        self.conversationHistory = conversationHistory
        self.attachments = attachments
    }
}

public struct AIAssistantConversationMessage: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AIAssistantAttachment: Equatable, Sendable {
    public let filename: String
    public let mimeType: String
    public let byteCount: Int
    public let base64Data: String?
    public let textPreview: String?
    public let localFileURL: URL?

    public init(
        filename: String,
        mimeType: String,
        byteCount: Int,
        base64Data: String? = nil,
        textPreview: String? = nil,
        localFileURL: URL? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.base64Data = base64Data
        self.textPreview = textPreview
        self.localFileURL = localFileURL
    }

    public var isImage: Bool {
        mimeType.lowercased().hasPrefix("image/")
    }

    public var dataURL: String? {
        guard isImage,
              let base64Data,
              base64Data.isEmpty == false
        else {
            return nil
        }
        return "data:\(mimeType);base64,\(base64Data)"
    }

    public var promptSummary: String {
        var parts = [
            "文件名：\(filename)",
            "类型：\(mimeType)",
            "大小：\(byteCount) bytes"
        ]
        if isImage, dataURL != nil {
            parts.append("内容：图片已作为视觉附件提供。")
        } else if isImage {
            parts.append("内容：图片过大或无法读取，仅提供元数据。")
        } else if let textPreview,
                  textPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("文本片段：\(textPreview)")
        } else {
            parts.append("内容：二进制或不可预览文件，仅提供元数据。")
        }
        return parts.joined(separator: "；")
    }
}

public enum AIAssistantRemoteFileAttachmentError: Error, Equatable {
    case noFileSelected
    case unsupportedProtocol
    case fileTooLarge
    case textOnly

    public var userMessage: String {
        switch self {
        case .noFileSelected:
            return "请先在文件面板选择一个文本文件"
        case .unsupportedProtocol:
            return "当前文件会话暂不支持作为 AI 上下文"
        case .fileTooLarge:
            return "文件过大，无法作为 AI 上下文"
        case .textOnly:
            return "仅支持文本文件"
        }
    }
}

public struct AIAssistantResponse: Equatable, @unchecked Sendable {
    public let message: String
    public let commandProposals: [AgentCommandProposal]

    public var proposedCommand: String? {
        commandProposals.first?.command
    }

    public init(message: String, proposedCommand: String?) {
        self.message = message
        if let proposedCommand,
           proposedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            self.commandProposals = [
                AgentCommandProposal(
                    command: proposedCommand,
                    explanation: "AI 建议执行此命令。"
                )
            ]
        } else {
            self.commandProposals = []
        }
    }

    public init(message: String, commandProposals: [AgentCommandProposal]) {
        self.message = message
        self.commandProposals = commandProposals
    }
}

public protocol AIAssistantProviding {
    func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse
}

public struct RuleBasedAIAssistantProvider: AIAssistantProviding {
    public init() {}

    public func respond(to request: AIAssistantRequest) throws -> AIAssistantResponse {
        let lower = request.question.lowercased()
        let question = request.question
        let mentionsContainers = lower.contains("docker")
            || lower.contains("container")
            || question.contains("容器")
        let mentionsDisk = lower.contains("disk")
            || question.contains("磁盘")
            || question.contains("空间")
            || question.contains("占用")
        let mentionsLoad = lower.contains("load")
            || lower.contains("cpu")
            || lower.contains("memory")
            || question.contains("负载")
            || question.contains("CPU")
            || question.contains("内存")
            || question.contains("卡")

        if mentionsDisk {
            var proposals = [
                AgentCommandProposal(command: "df -h", explanation: "查看各挂载点容量和使用率。", risk: .readOnly),
                AgentCommandProposal(command: "du -sh ./* 2>/dev/null | sort -h | tail -20", explanation: "在当前目录找出占用最大的条目。", risk: .readOnly)
            ]
            if mentionsContainers {
                proposals.append(
                    AgentCommandProposal(command: "docker system df", explanation: "查看 Docker 镜像、容器、卷和构建缓存占用。", risk: .readOnly)
                )
            }
            return AIAssistantResponse(message: "建议按分步只读诊断先定位磁盘占用。", commandProposals: proposals)
        }
        if mentionsLoad {
            return AIAssistantResponse(
                message: "建议按分步只读诊断先查看系统负载。",
                commandProposals: [
                    AgentCommandProposal(command: "uptime", explanation: "查看负载均值和系统运行时间。"),
                    AgentCommandProposal(command: "ps aux --sort=-%cpu | head -10", explanation: "查看 CPU 占用最高的进程。", risk: .readOnly),
                    AgentCommandProposal(command: "free -h", explanation: "查看内存和 swap 使用情况。", risk: .readOnly)
                ]
            )
        }
        if mentionsContainers {
            return AIAssistantResponse(
                message: "建议按分步只读诊断先查看容器状态和 Docker 占用。",
                commandProposals: [
                    AgentCommandProposal(command: "docker ps", explanation: "查看正在运行的容器。", risk: .readOnly),
                    AgentCommandProposal(command: "docker system df", explanation: "查看 Docker 镜像、容器、卷和构建缓存占用。", risk: .readOnly),
                    AgentCommandProposal(command: "docker images | head -20", explanation: "查看前 20 个镜像条目。", risk: .readOnly)
                ]
            )
        }
        return AIAssistantResponse(message: "我可以根据当前终端输出建议下一步命令。", proposedCommand: nil)
    }
}
