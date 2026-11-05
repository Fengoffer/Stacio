import AppKit
import Foundation

// MARK: - Composer 发送键模式（P5-1）

/// 两种 `sendKeyMode`：Return 发送 / Command+Return 发送。
public enum SendKeyMode: String, Codable, CaseIterable, Equatable, Sendable {
    case returnSends
    case commandReturnSends
}

// MARK: - 按键修饰符

public struct ComposerKeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ComposerKeyModifiers(rawValue: 1 << 0)
    public static let command = ComposerKeyModifiers(rawValue: 1 << 1)
    public static let option = ComposerKeyModifiers(rawValue: 1 << 2)
    public static let control = ComposerKeyModifiers(rawValue: 1 << 3)

    public static func from(_ event: NSEvent) -> ComposerKeyModifiers {
        var modifiers: ComposerKeyModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}

// MARK: - 按键动作

public enum ComposerKeyAction: Equatable, Sendable {
    case send
    case queue
    case requestAnswer
    case insertNewline
    /// marked text 存在时 Return 只能确认候选，不能发送。
    case confirmCandidate
    /// Escape 先取消输入法候选（hasMarkedText 时）或关闭最上层弹层；永不折叠助手/停止/清空。
    case cancelCompositionOrDismiss
    case stop
    case browseHistory(direction: ComposerHistoryDirection)
    case undo
    case redo
    case tabNavigation
    case none
}

public enum ComposerHistoryDirection: Equatable, Sendable {
    case previous
    case next
}

// MARK: - 按键路由（纯函数，可测）

public enum AgentComposerKeyRouter {
    public static let keyCodeReturn: UInt16 = 36
    public static let keyCodeEscape: UInt16 = 53
    public static let keyCodePeriod: UInt16 = 47
    public static let keyCodeUp: UInt16 = 126
    public static let keyCodeDown: UInt16 = 125
    public static let keyCodeZ: UInt16 = 6
    public static let keyCodeTab: UInt16 = 48
    /// IME 转换中（中文/日文/韩文输入法）的 keyCode 229 边界：交输入法处理，不路由任何动作。
    public static let keyCodeIME: UInt16 = 229

    /// 纯函数路由：keyDown 输入 → 动作。
    /// - `hasMarkedText`：输入法 marked text 存在；
    /// - `justCommitted`：输入法刚提交文字的同一按键周期（提交保护）。
    public static func route(
        keyCode: UInt16,
        modifiers: ComposerKeyModifiers,
        hasMarkedText: Bool,
        justCommitted: Bool,
        sendKeyMode: SendKeyMode,
        atStartBoundary: Bool,
        atEndBoundary: Bool,
        hasSelection: Bool
    ) -> ComposerKeyAction {
        // IME 转换中 keyCode 229：交输入法，永不路由
        if keyCode == keyCodeIME {
            return .none
        }
        // 输入法刚提交文字的同一按键周期：提交保护（不发送、不路由）
        if justCommitted {
            return .none
        }
        // marked text 存在：Return 只确认候选；Escape 取消候选；其余交输入法
        if hasMarkedText {
            if keyCode == keyCodeReturn {
                return .confirmCandidate
            }
            if keyCode == keyCodeEscape {
                return .cancelCompositionOrDismiss
            }
            return .none
        }
        // 无 marked text
        switch keyCode {
        case keyCodeReturn:
            if modifiers.contains(.command) {
                return .send // Command+Return 恒执行 Send 语义
            }
            if modifiers.contains(.option) {
                return .queue
            }
            if modifiers.contains(.shift) {
                return .insertNewline
            }
            return sendKeyMode == .returnSends ? .send : .insertNewline
        case keyCodeEscape:
            return .cancelCompositionOrDismiss
        case keyCodePeriod:
            return modifiers.contains(.command) ? .stop : .none
        case keyCodeUp:
            // 仅在光标首部边界且无选择时浏览已发送历史
            return atStartBoundary && !hasSelection ? .browseHistory(direction: .previous) : .none
        case keyCodeDown:
            return atEndBoundary && !hasSelection ? .browseHistory(direction: .next) : .none
        case keyCodeZ:
            if modifiers.contains(.command) {
                return modifiers.contains(.shift) ? .redo : .undo
            }
            return .none
        case keyCodeTab:
            return .tabNavigation
        default:
            return .none
        }
    }
}

// MARK: - AgentComposerTextView（NSTextView 子类）

/// 原生 Composer：IME 安全（marked text 存在时 Return 只确认候选）、
/// 输入法刚提交文字的同一按键周期提交保护、两种 sendKeyMode、Escape 分层、历史浏览。
@MainActor
public final class AgentComposerTextView: NSTextView {
    public var sendKeyMode: SendKeyMode = .returnSends
    public var onSend: (() -> Void)?
    public var onQueue: (() -> Void)?
    public var onRequestAnswer: (() -> Void)?
    public var onStop: (() -> Void)?
    public var onEscape: (() -> Void)?
    /// 已发送历史（Up/Down 浏览）。
    public var historyProvider: (() -> [String])?

    /// 输入法刚提交文字的同一按键周期提交保护标志。
    private var justCommittedInKeyCycle = false
    private var commitProtectionGeneration: UInt64 = 0
    private var historyCursor: Int?
    private var historyDraft = ""
    private var isApplyingHistory = false
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager

    /// 交原生行为钩子（测试注入；默认 nil 走 super.keyDown）。
    var forwardToSuperHandler: ((NSEvent) -> Void)?

    public init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        ownedTextStorage = textStorage
        ownedLayoutManager = layoutManager
        super.init(frame: .zero, textContainer: textContainer)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        isRichText = false
        allowsUndo = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public var hasMarkedText: Bool {
        let range = markedRange()
        return range.location != NSNotFound && range.length > 0
    }

    override public func keyDown(with event: NSEvent) {
        let action = AgentComposerKeyRouter.route(
            keyCode: event.keyCode,
            modifiers: ComposerKeyModifiers.from(event),
            hasMarkedText: hasMarkedText,
            justCommitted: justCommittedInKeyCycle,
            sendKeyMode: sendKeyMode,
            atStartBoundary: selectedRange().location == 0,
            atEndBoundary: selectedRange().location + selectedRange().length == (string as NSString).length,
            hasSelection: selectedRange().length > 0
        )
        // 提交保护：仅当前按键周期有效，下一 keyDown 清除
        justCommittedInKeyCycle = false
        dispatch(action, event: event)
    }

    private func dispatch(_ action: ComposerKeyAction, event: NSEvent?) {
        switch action {
        case .send:
            resetHistoryNavigation()
            onSend?()
        case .queue:
            resetHistoryNavigation()
            if let onQueue {
                onQueue()
            } else {
                // A surface without a visible queue must preserve Option+Return
                // as text input instead of swallowing it or enqueueing invisibly.
                forwardToNativeBehavior(event)
            }
        case .requestAnswer:
            onRequestAnswer?()
        case .stop:
            onStop?()
        case .browseHistory(let direction):
            browseHistory(direction)
        case .cancelCompositionOrDismiss:
            if hasMarkedText {
                forwardToNativeBehavior(event)
            } else {
                onEscape?()
            }
        case .insertNewline, .confirmCandidate, .tabNavigation, .undo, .redo, .none:
            // 交回原生行为（undo/redo/换行/Tab/输入法候选确认/光标移动）——
            // 不吞键：Command+Z、Shift+Return 换行、候选确认等必须执行原生语义。
            forwardToNativeBehavior(event)
        }
    }

    private func forwardToNativeBehavior(_ event: NSEvent?) {
        guard let event else { return }
        if let handler = forwardToSuperHandler {
            handler(event)
        } else {
            super.keyDown(with: event)
        }
    }

    private func browseHistory(_ direction: ComposerHistoryDirection) {
        let history = historyProvider?() ?? []
        guard history.isEmpty == false else { return }
        let nextIndex: Int?
        switch direction {
        case .previous:
            if let historyCursor {
                // The provider can be rebuilt during restore or cross-window
                // updates. Never trust a cursor captured from an older list.
                let clampedCursor = min(max(0, historyCursor), history.count - 1)
                nextIndex = max(0, clampedCursor - 1)
            } else {
                historyDraft = string
                nextIndex = history.count - 1
            }
        case .next:
            guard let historyCursor else { return }
            let clampedCursor = min(max(0, historyCursor), history.count - 1)
            nextIndex = clampedCursor + 1 < history.count ? clampedCursor + 1 : nil
        }

        isApplyingHistory = true
        if let nextIndex {
            historyCursor = nextIndex
            string = history[nextIndex]
        } else {
            historyCursor = nil
            string = historyDraft
        }
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        // Programmatic text-storage changes do not reliably emit the native
        // NSText change notification. Publish it explicitly so the owning
        // composer updates its placeholder, send state and durable draft.
        didChangeText()
        isApplyingHistory = false
    }

    private func resetHistoryNavigation() {
        historyCursor = nil
        historyDraft = ""
    }

    override public func didChangeText() {
        super.didChangeText()
        if isApplyingHistory == false {
            resetHistoryNavigation()
        }
    }

    /// 输入法提交文字后由 NSTextInputClient 回调调用（同一按键周期提交保护）。
    public func markTextCommittedInCurrentKeyCycle() {
        commitProtectionGeneration &+= 1
        let generation = commitProtectionGeneration
        justCommittedInKeyCycle = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.commitProtectionGeneration == generation else { return }
            self.justCommittedInKeyCycle = false
        }
    }

    /// P0-9：IME 提交保护——输入法通过 insertText 提交文字时标记当前按键周期，
    /// 防止同一按键的 Return 被误判为发送（中文/日文输入法 commit + Return 边界）。
    override public func insertText(_ string: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText
        super.insertText(string, replacementRange: replacementRange)
        if wasComposing {
            markTextCommittedInCurrentKeyCycle()
        }
    }

    /// 供测试的同步分发入口。
    public func handleKeyForTesting(
        keyCode: UInt16, modifiers: ComposerKeyModifiers = [], hasSelection: Bool = false
    ) {
        let action = AgentComposerKeyRouter.route(
            keyCode: keyCode,
            modifiers: modifiers,
            hasMarkedText: hasMarkedText,
            justCommitted: justCommittedInKeyCycle,
            sendKeyMode: sendKeyMode,
            atStartBoundary: selectedRange().location == 0,
            atEndBoundary: selectedRange().location + selectedRange().length == (string as NSString).length,
            hasSelection: hasSelection
        )
        justCommittedInKeyCycle = false
        dispatch(action, event: nil)
    }
}
