import Foundation

// MARK: - Composer 草稿持久化与原子提交（P5-3）

/// 每会话独立的结构化草稿。
public struct ComposerDraft: Equatable, Sendable {
    public let conversationID: String
    public var text: String
    public var attachments: [String]
    public var contextSelections: [String]
    public var revision: Int
    public var workMode: TurnWorkMode
    public var executionChoice: TurnExecutionChoice
    public var fixedRuntimeID: String?

    public init(
        conversationID: String, text: String = "", attachments: [String] = [],
        contextSelections: [String] = [], revision: Int = 1,
        workMode: TurnWorkMode = .agent,
        executionChoice: TurnExecutionChoice = .realTerminal,
        fixedRuntimeID: String? = nil
    ) {
        self.conversationID = conversationID
        self.text = text
        self.attachments = attachments
        self.contextSelections = contextSelections
        self.revision = revision
        self.workMode = workMode
        self.executionChoice = executionChoice
        self.fixedRuntimeID = fixedRuntimeID
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty && contextSelections.isEmpty
    }
}

public enum ComposerCommitOutcome: Equatable, Sendable {
    /// Turn 成功创建：原文从 pending draft 删除。
    case committed
    /// 创建失败：原文/附件/上下文选择全部恢复。
    case failedAndRestored
}

/// 提交-回滚契约：提交动作可立即清空可见编辑区，但原文只在 Turn 成功创建后从 pending 删除。
public struct ComposerCommitPlan: Equatable, Sendable {
    public let clearsVisibleEditor: Bool
    public let retainsPendingOriginal: Bool
    public let outcome: ComposerCommitOutcome

    public init(clearsVisibleEditor: Bool, retainsPendingOriginal: Bool, outcome: ComposerCommitOutcome) {
        self.clearsVisibleEditor = clearsVisibleEditor
        self.retainsPendingOriginal = retainsPendingOriginal
        self.outcome = outcome
    }
}

/// 队列项（可编辑）：独立 revision/原文/附件/上下文/工作模式/终端模式/可选固定 Runtime。
public struct ComposerQueueItem: Equatable, Sendable {
    public let itemID: String
    public var originalText: String
    public var attachments: [String]
    public var contextSelections: [String]
    public var workMode: TurnWorkMode
    public var executionChoice: TurnExecutionChoice
    public var fixedRuntimeID: String?
    public var revision: Int

    public init(
        itemID: String, originalText: String, attachments: [String] = [],
        contextSelections: [String] = [], workMode: TurnWorkMode = .agent,
        executionChoice: TurnExecutionChoice = .realTerminal,
        fixedRuntimeID: String? = nil, revision: Int = 1
    ) {
        self.itemID = itemID
        self.originalText = originalText
        self.attachments = attachments
        self.contextSelections = contextSelections
        self.workMode = workMode
        self.executionChoice = executionChoice
        self.fixedRuntimeID = fixedRuntimeID
        self.revision = revision
    }
}

public enum ComposerDraftPersistence {

    /// 250ms debounce 落盘。
    public static let debounceInterval: TimeInterval = 0.25

    public static func shouldPersist(elapsedSinceLastSave: TimeInterval) -> Bool {
        elapsedSinceLastSave >= debounceInterval
    }

    /// 每会话独立草稿键；切换会话/Runtime/目标不覆盖其他草稿。
    public static func draftKey(conversationID: String) -> String {
        "composer.draft.\(conversationID)"
    }

    /// 空白消息不可发送。
    public static func canSend(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 提交-回滚：提交动作可立即清空可见编辑区，但原文只在 Turn 成功创建后删除；
    /// 创建失败时原文/附件/上下文选择全部恢复。
    public static func commitPlan(created: Bool) -> ComposerCommitPlan {
        if created {
            return ComposerCommitPlan(
                clearsVisibleEditor: true,
                retainsPendingOriginal: false,
                outcome: .committed
            )
        }
        return ComposerCommitPlan(
            clearsVisibleEditor: true,
            retainsPendingOriginal: true,
            outcome: .failedAndRestored
        )
    }

    /// 编辑用 revision CAS：不能覆盖已提升的旧版本。
    public static func canEditQueueItem(
        _ item: ComposerQueueItem, expectedRevision: Int, currentRevision: Int
    ) -> Bool {
        guard expectedRevision == currentRevision else { return false }
        return item.revision == currentRevision
    }

    /// 编辑后 revision 递增。
    public static func bumpedRevision(_ current: Int) -> Int {
        current + 1
    }

    // MARK: - 运行中状态

    /// WaitingForCapacity 上方内联状态：第 N 位 · 已等待 mm:ss · 取消等待 · 打开 Agent 执行设置。
    public static func waitingForCapacityStatus(position: Int, waitedSeconds: Int) -> String {
        let minutes = waitedSeconds / 60
        let seconds = waitedSeconds % 60
        return String(format: "第 %d 位 · 已等待 %02d:%02d · 取消等待 · 打开 Agent 执行设置", position, minutes, seconds)
    }

    /// 获准后立即切换 StartingRuntime。
    public static func capacityGrantedSwitchesToStartingRuntime() -> Bool { true }

    /// Paused 显示暂停依据/checkpoint 时间/独立 Resume。
    public static func pausedStatus(reason: String, checkpointAt: Date?) -> String {
        guard let checkpointAt else {
            return "已暂停：\(reason) · Resume"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "已暂停：\(reason) · checkpoint \(formatter.string(from: checkpointAt)) · Resume"
    }
}
