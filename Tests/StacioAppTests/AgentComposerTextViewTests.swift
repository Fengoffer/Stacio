import XCTest
import AppKit
import Foundation
@testable import StacioApp

/// P5-1：AgentComposerTextView（原生 NSTextView + IME 安全）。
@MainActor
final class AgentComposerTextViewTests: XCTestCase {

    private func makeComposer(
        mode: SendKeyMode = .returnSends,
        text: String = "",
        markedTextRange: NSRange? = nil
    ) -> AgentComposerTextView {
        let composer = AgentComposerTextView()
        composer.string = text
        composer.sendKeyMode = mode
        composer.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        return composer
    }

    // MARK: - Router 纯函数（无 marked text）

    func testReturnSendsInReturnSendsMode() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeReturn, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .send)
    }

    func testReturnInsertsNewlineInCommandReturnSendsMode() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeReturn, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .commandReturnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .insertNewline)
    }

    func testShiftReturnInsertsNewline() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeReturn, modifiers: [.shift],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .insertNewline, "Shift+Return 换行")
    }

    func testCommandReturnAlwaysSendsInBothModes() {
        for mode in SendKeyMode.allCases {
            let action = AgentComposerKeyRouter.route(
                keyCode: AgentComposerKeyRouter.keyCodeReturn, modifiers: [.command],
                hasMarkedText: false, justCommitted: false, sendKeyMode: mode,
                atStartBoundary: false, atEndBoundary: true, hasSelection: false
            )
            XCTAssertEqual(action, .send, "Command+Return 恒执行 Send 语义（\(mode.rawValue)）")
        }
    }

    // MARK: - IME 保护

    func testMarkedTextReturnConfirmsCandidateNotSend() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeReturn, modifiers: [],
            hasMarkedText: true, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .confirmCandidate, "marked text 存在时 Return 只能确认候选不能发送")
    }

    func testMarkedTextEscapeCancelsComposition() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeEscape, modifiers: [],
            hasMarkedText: true, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .cancelCompositionOrDismiss)
    }

    func testJustCommittedSameKeyCycleProtection() {
        // 输入法刚提交文字的同一按键周期：Return 不发送
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeReturn, modifiers: [],
            hasMarkedText: false, justCommitted: true, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .none, "同一按键周期提交保护：不发送")
    }

    func testKeyCode229BypassesRouting() {
        // 中文/日文/韩文 IME 转换中的 keyCode 229：交输入法，不路由任何动作
        let action = AgentComposerKeyRouter.route(
            keyCode: 229, modifiers: [.command],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .none, "keyCode 229 边界：永不发送/路由")
    }

    // MARK: - Escape / Stop

    func testEscapeDismissesPopoverNeverCollapsesOrClears() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeEscape, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .cancelCompositionOrDismiss, "Escape 关闭最上层弹层")
        // Escape 永不映射为 send/stop/clear：路由只有 cancelCompositionOrDismiss
        XCTAssertNotEqual(action, .send)
        XCTAssertNotEqual(action, .stop)
    }

    func testCommandPeriodStops() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodePeriod, modifiers: [.command],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .stop, "Command+. 停止")
    }

    // MARK: - 历史浏览边界

    func testUpOnlyAtStartBoundaryWithoutSelection() {
        // 光标首部 + 无选择 → 浏览上一条
        let atStart = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeUp, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: true, atEndBoundary: false, hasSelection: false
        )
        XCTAssertEqual(atStart, .browseHistory(direction: .previous))
        // 有选择 → 不浏览
        let withSelection = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeUp, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: true, atEndBoundary: false, hasSelection: true
        )
        XCTAssertEqual(withSelection, .none)
        // 光标不在首部 → 交编辑
        let midText = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeUp, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: false, hasSelection: false
        )
        XCTAssertEqual(midText, .none)
    }

    func testDownOnlyAtEndBoundaryWithoutSelection() {
        let atEnd = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeDown, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(atEnd, .browseHistory(direction: .next))
        let midText = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeDown, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: false, hasSelection: false
        )
        XCTAssertEqual(midText, .none)
    }

    // MARK: - Undo/Redo/Tab

    func testUndoRedoNative() {
        let undo = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeZ, modifiers: [.command],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: true, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(undo, .undo, "Command+Z 原生 Undo")
        let redo = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeZ, modifiers: [.command, .shift],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: true, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(redo, .redo, "Shift+Command+Z 原生 Redo")
    }

    func testTabNavigates() {
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeTab, modifiers: [],
            hasMarkedText: false, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .tabNavigation, "Tab 导航")
    }

    // MARK: - TextView 分发（回调）

    func testTextViewDispatchSendAndStop() {
        let composer = makeComposer()
        var sent = 0
        var stopped = 0
        composer.onSend = { sent += 1 }
        composer.onStop = { stopped += 1 }

        composer.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        XCTAssertEqual(sent, 1, "Return 触发 onSend")
        composer.handleKeyForTesting(
            keyCode: AgentComposerKeyRouter.keyCodePeriod, modifiers: [.command]
        )
        XCTAssertEqual(stopped, 1, "Command+. 触发 onStop")
        XCTAssertEqual(sent, 1, "Command+. 不触发 onSend")
    }

    func testMarkedTextReturnDoesNotSendInTextView() {
        let composer = makeComposer(text: "你好")
        var sent = 0
        composer.onSend = { sent += 1 }
        // 模拟 marked text（输入法候选）：Return 只确认候选不发送
        _ = composer
        let action = AgentComposerKeyRouter.route(
            keyCode: AgentComposerKeyRouter.keyCodeReturn, modifiers: [],
            hasMarkedText: true, justCommitted: false, sendKeyMode: .returnSends,
            atStartBoundary: false, atEndBoundary: true, hasSelection: false
        )
        XCTAssertEqual(action, .confirmCandidate)
        XCTAssertEqual(sent, 0, "marked text 期间 Return 不发送")
    }

    func testPlainInsertTextDoesNotSuppressFollowingReturn() {
        let composer = makeComposer()
        var sent = 0
        composer.onSend = { sent += 1 }

        composer.insertText("普通输入", replacementRange: NSRange(location: 0, length: 0))
        composer.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)

        XCTAssertEqual(composer.string, "普通输入")
        XCTAssertEqual(sent, 1, "非输入法组合提交不能误触发 IME 保护而吞掉下一次 Return")
    }

    func testHistoryCursorSurvivesProviderListBeingRebuilt() {
        let composer = makeComposer(text: "未发送草稿")
        var history = ["第一条", "第二条", "第三条"]
        composer.historyProvider = { history }

        composer.setSelectedRange(NSRange(location: 0, length: 0))
        composer.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeUp)
        XCTAssertEqual(composer.string, "第三条")

        history = ["第一条"]
        composer.setSelectedRange(NSRange(location: 0, length: 0))
        composer.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeUp)
        XCTAssertEqual(composer.string, "第一条", "恢复重建历史后游标必须被夹到有效范围")

        composer.setSelectedRange(NSRange(location: (composer.string as NSString).length, length: 0))
        composer.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeDown)
        XCTAssertEqual(composer.string, "未发送草稿")
    }
}

// MARK: - 不吞键（Review 第 6 轮修复回归）

extension AgentComposerTextViewTests {

    func testUndoRedoNewlineNotSwallowed() throws {
        let composer = makeComposer()
        composer.sendKeyMode = .returnSends
        var forwardedEvents = 0
        composer.forwardToSuperHandler = { _ in forwardedEvents += 1 }

        // Command+Z → .undo → 必须交回原生行为（不吞键）
        let undoEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "z",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
        )!
        composer.keyDown(with: undoEvent)
        XCTAssertEqual(forwardedEvents, 1, "Command+Z 必须交回原生 undo，不吞键")

        // Shift+Return → .insertNewline → 交回原生（换行）
        let newlineEvent = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        )!
        composer.keyDown(with: newlineEvent)
        XCTAssertEqual(forwardedEvents, 2, "Shift+Return 换行交回原生")
    }
}
