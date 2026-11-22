import AppKit

public enum AITranscriptRole {
    case user
    case assistant
    case system
    case command
    case terminal
    case plan
    case step

    public var isProcessRole: Bool {
        switch self {
        case .command, .terminal, .plan, .step:
            return true
        case .user, .assistant, .system:
            return false
        }
    }

    /// Horizontal alignment of this role inside the transcript column.
    public enum TranscriptAlignment {
        case leading
        case trailing
        case centered
    }

    /// Visual weight of the role. Content roles carry the reading load;
    /// process roles are narration and must recede behind it.
    public enum TranscriptVisualTier {
        case primary
        case secondary
        case tertiary
    }

    public var transcriptAlignment: TranscriptAlignment {
        switch self {
        case .user:
            return .trailing
        case .system:
            return .centered
        case .assistant, .command, .terminal, .plan, .step:
            return .leading
        }
    }

    public var transcriptVisualTier: TranscriptVisualTier {
        switch self {
        case .user, .assistant:
            return .primary
        case .plan, .command, .terminal:
            return .secondary
        case .step, .system:
            return .tertiary
        }
    }

    /// Fraction of the available column width this role may occupy.
    public var transcriptMaxWidthRatio: CGFloat {
        switch self {
        case .user:
            return 0.78
        case .system:
            return 0.78
        case .assistant, .command, .terminal, .plan, .step:
            return 1.0
        }
    }

    public init(historyRole: AIConversationHistoryRole) {
        switch historyRole {
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .command:
            self = .command
        case .terminal:
            self = .terminal
        case .plan:
            self = .plan
        case .step:
            self = .step
        }
    }

    public var historyRole: AIConversationHistoryRole {
        switch self {
        case .user:
            return .user
        case .assistant:
            return .assistant
        case .system:
            return .assistant
        case .command:
            return .command
        case .terminal:
            return .terminal
        case .plan:
            return .plan
        case .step:
            return .step
        }
    }

    public var persistedHistoryRole: AIConversationHistoryRole? {
        switch self {
        case .system:
            return nil
        default:
            return historyRole
        }
    }
}

public struct AITranscriptAttachment: Equatable {
    public let filename: String
    public let displayKind: String
    public let byteCount: Int
    public let isImage: Bool
 
    public init(_ attachment: AIAssistantAttachment) {
        filename = attachment.filename
        displayKind = attachment.displayKind
        byteCount = attachment.byteCount
        isImage = attachment.isImage
    }

    public var metadataText: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(displayKind) · \(size)"
    }
}

public struct AITranscriptEntry {
    public let id: UUID
    public let role: AITranscriptRole
    public var text: String
    public var conversationContent: String? = nil
    public var attachments: [AITranscriptAttachment] = []
    public let requestID: String?
    public var isProcessEntry: Bool = false
    public var processGroupID: UUID? = nil
    public var isCollapsed: Bool = false
    /// True while this entry is still receiving streamed text. Re-rendering an
    /// unfinished answer skips table layout, which dominates the cost.
    public var isStreaming: Bool = false
    public var createdAt: Date = Date()
    public var executionCard: ExecutionCardPresentation? = nil

    public init(
        id: UUID = UUID(),
        role: AITranscriptRole,
        text: String,
        conversationContent: String? = nil,
        attachments: [AITranscriptAttachment] = [],
        requestID: String?,
        isProcessEntry: Bool = false,
        processGroupID: UUID? = nil,
        isCollapsed: Bool = false,
        createdAt: Date = Date(),
        executionCard: ExecutionCardPresentation? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.conversationContent = conversationContent
        self.attachments = attachments
        self.requestID = requestID
        self.isProcessEntry = isProcessEntry
        self.processGroupID = processGroupID
        self.isCollapsed = isCollapsed
        self.createdAt = createdAt
        self.executionCard = executionCard
    }

    public var displayText: String {
        guard isCollapsed else { return text }
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        return "\(firstLine) · 已折叠，点击展开"
    }

    public var font: NSFont {
        switch role {
        case .user:
            return .systemFont(ofSize: 12, weight: .semibold)
        case .assistant:
            return .systemFont(ofSize: 12)
        case .system:
            return .systemFont(ofSize: 11, weight: .medium)
        case .command:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .terminal:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .plan:
            return .systemFont(ofSize: 12, weight: .medium)
        case .step:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
    }

    public var textColor: NSColor {
        switch role {
        case .user:
            return StacioDesignSystem.theme.primaryTextColor
        case .assistant:
            return StacioDesignSystem.theme.primaryTextColor
        case .system:
            return StacioDesignSystem.theme.secondaryTextColor
        case .command:
            return StacioDesignSystem.theme.primaryTextColor
        case .terminal:
            return StacioDesignSystem.theme.primaryTextColor
        case .plan:
            return StacioDesignSystem.theme.primaryTextColor
        case .step:
            return StacioDesignSystem.theme.secondaryTextColor
        }
    }

    public var bubbleAccessibilityIdentifier: String {
        switch role {
        case .user:
            return "Stacio.AI.transcript.userBubble"
        case .assistant:
            return "Stacio.AI.transcript.assistantBubble"
        case .system:
            return "Stacio.AI.transcript.systemBubble"
        case .command:
            return "Stacio.AI.transcript.commandBubble"
        case .terminal:
            return "Stacio.AI.transcript.terminalBubble"
        case .plan:
            return "Stacio.AI.transcript.planBubble"
        case .step:
            return "Stacio.AI.transcript.stepBubble"
        }
    }

    public var textAccessibilityIdentifier: String {
        switch role {
        case .user:
            return "Stacio.AI.transcript.userText"
        case .assistant:
            return "Stacio.AI.transcript.assistantText"
        case .system:
            return "Stacio.AI.transcript.systemText"
        case .command:
            return "Stacio.AI.transcript.commandText"
        case .terminal:
            return "Stacio.AI.transcript.terminalText"
        case .plan:
            return "Stacio.AI.transcript.planText"
        case .step:
            return "Stacio.AI.transcript.stepText"
        }
    }

    public var bubbleColor: NSColor {
        switch role {
        case .user:
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.48)
        case .assistant:
            return .clear
        case .system:
            return .clear
        case .command:
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.34)
        case .terminal:
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.36)
        case .plan:
            return StacioDesignSystem.theme.elevatedPanelColor.withAlphaComponent(0.72)
        case .step:
            return StacioDesignSystem.theme.controlBackgroundColor.withAlphaComponent(0.28)
        }
    }

    public var borderColor: NSColor? {
        switch role {
        case .user:
            return StacioDesignSystem.theme.accentColor.withAlphaComponent(0.32)
        case .assistant, .system:
            return nil
        case .command, .terminal:
            return StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.2)
        case .plan:
            return StacioDesignSystem.theme.accentColor.withAlphaComponent(0.28)
        case .step:
            return StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.18)
        }
    }

    public var bubbleCornerRadius: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return StacioDesignSystem.theme.panelCornerRadius
        case .user:
            return StacioDesignSystem.theme.panelCornerRadius
        case .assistant, .system:
            return 0
        }
    }

    public var horizontalPadding: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return 12
        case .user:
            return 13
        case .assistant:
            return 0
        case .system:
            return 8
        }
    }

    public var verticalPadding: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return 10
        case .user:
            return 10
        case .assistant:
            return 8
        case .system:
            return 4
        }
    }

    public var verticalInset: CGFloat {
        switch role {
        case .command, .terminal, .plan, .step:
            return 2
        case .user, .assistant:
            return 1
        case .system:
            return 1
        }
    }
}
