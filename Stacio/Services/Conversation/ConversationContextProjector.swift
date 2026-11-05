import Foundation

// MARK: - 上下文投影（规格 §15.3 白名单）

public enum ContextProjectionItemKind: String, Codable, CaseIterable, Equatable, Sendable {
    // 白名单
    case systemPolicy
    case instructionSnapshot
    case targetInfo
    case userMessage
    case finalAnswer
    case decisionAnswer
    case approvedToolResultSummary
    case explicitAttachment
    case planState
    case userConfirmedMemory
    // 排除项（用于断言与拒绝）
    case uiState
    case unsentQueue
    case unapprovedCommand
    case hiddenChainOfThought
    case terminalScrollback
    case sensitiveInput
    case otherBranchContent
    case otherHostContent

    public var isAllowedByWhitelist: Bool {
        switch self {
        case .systemPolicy, .instructionSnapshot, .targetInfo, .userMessage,
             .finalAnswer, .decisionAnswer, .approvedToolResultSummary,
             .explicitAttachment, .planState, .userConfirmedMemory:
            return true
        case .uiState, .unsentQueue, .unapprovedCommand, .hiddenChainOfThought,
             .terminalScrollback, .sensitiveInput, .otherBranchContent, .otherHostContent:
            return false
        }
    }
}

public struct ContextProjectionItem: Codable, Equatable, Sendable {
    public var kind: ContextProjectionItemKind
    public var content: String
    public var source: String

    public init(kind: ContextProjectionItemKind, content: String, source: String) {
        self.kind = kind
        self.content = content
        self.source = source
    }

    public static func digest(of item: ContextProjectionItem) -> String {
        "\(item.kind.rawValue)|\(item.source)|\(item.content.count)"
    }
}

public struct ContextProjectionRequest: Equatable, Sendable {
    public var conversationID: String
    public var items: [ContextProjectionItem]

    public init(conversationID: String, items: [ContextProjectionItem]) {
        self.conversationID = conversationID
        self.items = items
    }
}

public enum ContextProjectionAllowance: Equatable, Sendable {
    case allowed
    case excluded(reason: String)
}

// MARK: - 分支基座快照

/// 分支创建时原子生成的自包含上下文快照（只含分叉点前白名单内容；子分支不读父会话分叉点后内容）。
public struct BranchBaseContextSnapshot: Equatable, Sendable {
    public var parentConversationID: String
    public var forkedAtSequence: Int
    public var sourceUserMessageID: String
    public var contentItems: [ContextProjectionItem]
    public var digest: String

    public init(
        parentConversationID: String,
        forkedAtSequence: Int,
        sourceUserMessageID: String,
        contentItems: [ContextProjectionItem],
        digest: String
    ) {
        self.parentConversationID = parentConversationID
        self.forkedAtSequence = forkedAtSequence
        self.sourceUserMessageID = sourceUserMessageID
        self.contentItems = contentItems
        self.digest = digest
    }
}

public enum ConversationContextProjector {
    /// 白名单判定。
    public static func allowance(for item: ContextProjectionItem) -> ContextProjectionAllowance {
        item.kind.isAllowedByWhitelist ? .allowed : .excluded(reason: "白名单外")
    }

    /// 投影：只保留白名单项（保持顺序）。
    public static func project(request: ContextProjectionRequest) -> [ContextProjectionItem] {
        request.items.filter { $0.kind.isAllowedByWhitelist }
    }

    /// 分支创建：生成自包含 BranchBaseContextSnapshot（preForkItems 为分叉点前白名单内容；
    /// `digestOfPostForkContent` 仅用于审计证明不读取分叉点后内容）。
    public static func branchBaseSnapshot(
        parentConversationID: String,
        forkedAtSequence: Int,
        sourceUserMessageID: String = "",
        preForkItems: [ContextProjectionItem],
        digestOfPostForkContent: String
    ) -> BranchBaseContextSnapshot {
        let allowed = preForkItems.filter { $0.kind.isAllowedByWhitelist }
        let digest = [
            "parent=\(parentConversationID)",
            "forkedAt=\(forkedAtSequence)",
            "items=\(allowed.map { "\($0.kind.rawValue):\($0.source)" }.joined(separator: ","))",
            "postForkDigest=\(digestOfPostForkContent)"
        ].joined(separator: "|")
        return BranchBaseContextSnapshot(
            parentConversationID: parentConversationID,
            forkedAtSequence: forkedAtSequence,
            sourceUserMessageID: sourceUserMessageID,
            contentItems: allowed,
            digest: digest
        )
    }
}
