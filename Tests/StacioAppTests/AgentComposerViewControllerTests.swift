import XCTest
import AppKit
import Foundation
@testable import StacioApp

/// P5-2：AgentComposerViewController（布局度量、执行身份、模型/推理/上下文/目标菜单语义、Send/Stop 状态机）。
final class AgentComposerViewControllerTests: XCTestCase {

    // MARK: - 输入区高度

    func testInputHeightGrowsToCapNotSqueezingTimeline() {
        // 最小约两行
        XCTAssertEqual(
            AgentComposerLayout.inputHeight(contentHeight: 10, availableHeight: 600),
            AgentComposerLayout.lineHeight * AgentComposerLayout.minInputLines,
            "最小约两行"
        )
        // 内容增长到 min(180, 可用 35%)
        let available = 600.0
        let cap = min(180.0, available * 0.35) // 180
        XCTAssertEqual(
            AgentComposerLayout.inputHeight(contentHeight: 500, availableHeight: available),
            cap,
            "达 min(180pt, 会话可用高度 35%) 上限"
        )
        // 可用高度小时按 35%
        let shortAvailable = 400.0
        XCTAssertEqual(
            AgentComposerLayout.inputHeight(contentHeight: 500, availableHeight: shortAvailable),
            shortAvailable * 0.35
        )
        // 达限内部滚动不挤压时间线
        XCTAssertTrue(
            AgentComposerLayout.scrollsInternallyWhenAtLimit(contentHeight: 500, availableHeight: 400),
            "达限内部滚动"
        )
        XCTAssertFalse(
            AgentComposerLayout.scrollsInternallyWhenAtLimit(contentHeight: 100, availableHeight: 600)
        )
    }

    // MARK: - 附件区/队列区

    func testAttachmentAndQueueAreaOnlyWithContent() {
        XCTAssertFalse(AgentComposerLayout.attachmentAreaVisible(itemCount: 0), "无附件不显示附件区")
        XCTAssertTrue(AgentComposerLayout.attachmentAreaVisible(itemCount: 1))
        XCTAssertFalse(AgentComposerLayout.queueAreaVisible(itemCount: 0), "无排队不显示队列区")
        XCTAssertTrue(AgentComposerLayout.queueAreaVisible(itemCount: 2))
    }

    // MARK: - Send/Stop 布局

    func testNativeComposerUsesOnePinnedPrimaryAction() {
        XCTAssertTrue(AgentComposerLayout.sendPinnedToBottomRight(), "主操作键固定右下")
        XCTAssertTrue(AgentComposerLayout.stopNeverShiftsSend(), "图标切换不改变主操作键位置")
        XCTAssertTrue(AgentComposerLayout.usesSinglePrimaryActionForNativeConversation())
    }

    func testNarrowModeCollectsMenusButPrimaryActionStaysVisible() {
        XCTAssertTrue(AgentComposerLayout.narrowModeCollectsRuntimeModelIntoMenu(width: 500), "窄宽度收进菜单")
        XCTAssertFalse(AgentComposerLayout.narrowModeCollectsRuntimeModelIntoMenu(width: 800))
        XCTAssertTrue(AgentComposerLayout.usesSinglePrimaryActionForNativeConversation())
    }

    // MARK: - 执行身份显示

    func testComposerIdentityDisplay() {
        XCTAssertEqual(
            AgentComposerSemantics.identityDisplay(.native(modelDisplayName: "Kimi")),
            "Native · Kimi"
        )
        XCTAssertEqual(
            AgentComposerSemantics.identityDisplay(.localAgent(runtimeName: "Codex", mode: .controlled)),
            "Stacio Agent · Codex · 受控"
        )
        XCTAssertEqual(
            AgentComposerSemantics.identityDisplay(.localAgent(runtimeName: "Codex", mode: .terminalPassthrough)),
            "Stacio Agent · Codex · 终端透传"
        )
    }

    // MARK: - 模型菜单与推理强度

    func testModelMenuOnlySyncedAndEnabled() {
        let models = [
            ComposerModelEntry(modelID: "kimi-k2", syncedFromUpstream: true, enabled: true),
            ComposerModelEntry(modelID: "stale-model", syncedFromUpstream: false, enabled: true),
            ComposerModelEntry(modelID: "disabled-model", syncedFromUpstream: true, enabled: false),
            ComposerModelEntry(modelID: "legacy", syncedFromUpstream: false, enabled: false)
        ]
        XCTAssertEqual(
            AgentComposerSemantics.modelMenuEntries(models).map(\.modelID),
            ["kimi-k2"],
            "模型菜单只显示上游同步且已启用模型"
        )
    }

    func testReasoningLevelsOnlyCurrentModelSupported() {
        XCTAssertEqual(
            AgentComposerSemantics.reasoningLevels(supportedLevels: ["low", "high"]),
            ["low", "high"]
        )
        XCTAssertEqual(
            AgentComposerSemantics.reasoningLevels(supportedLevels: []),
            [],
            "当前模型不支持的档位不显示"
        )
    }

    // MARK: - 工作方式与执行选择

    func testWorkModesAreTurnScopeAndLocalAgentIsRuntime() {
        XCTAssertEqual(AgentComposerSemantics.workModes(), [.agent, .planFirst, .answerOnly])
        XCTAssertEqual(TurnWorkMode.agent.displayName, "Agent")
        XCTAssertEqual(TurnWorkMode.planFirst.displayName, "先规划")
        XCTAssertEqual(TurnWorkMode.answerOnly.displayName, "仅回答")
        XCTAssertTrue(AgentComposerSemantics.localAgentIsRuntimeNotWorkMode(), "Local Agent 是 Runtime 不是第四种工作方式")
        // 执行选择与模型菜单分离
        XCTAssertEqual(TurnExecutionChoice.allCases.count, 3)
        XCTAssertTrue(TurnExecutionChoice.allCases.contains(.ask))
        XCTAssertTrue(TurnExecutionChoice.allCases.contains(.realTerminal))
        XCTAssertTrue(TurnExecutionChoice.allCases.contains(.backgroundVirtualTerminal))
    }

    // MARK: - 上下文用量环

    func testContextUsageRuntimeVerifiedBudget() {
        XCTAssertEqual(
            AgentComposerSemantics.contextUsageDisplay(runtimeVerifiedBudgetKiB: 64_000, sentKiB: 32_000),
            "已发送 32000 KiB / 64000 KiB (50%)"
        )
    }

    func testContextUsageUnknownForLocalAgent() {
        XCTAssertEqual(
            AgentComposerSemantics.contextUsageDisplay(runtimeVerifiedBudgetKiB: nil, sentKiB: 1_024),
            "已发送 1024 KiB · CLI 内部上下文未知",
            "Local Agent 未验证 contextUsageReporting 显示「已发送 N KiB · CLI 内部上下文未知」"
        )
    }

    // MARK: - 目标身份菜单

    func testTargetDirectoryDisplaySeparatesTargetAndMacLocal() {
        XCTAssertEqual(
            AgentComposerSemantics.targetDirectoryDisplay(
                remoteOrLocalTargetDirectory: "/home/deploy/app",
                macLocalWorkingDirectory: "/Users/mac/stacio"
            ),
            "/home/deploy/app · /Users/mac/stacio",
            "远端/本地 targetWorkingDirectory 与 Mac 本地 AgentProcessWorkingDirectory 分别显示"
        )
        XCTAssertEqual(
            AgentComposerSemantics.targetDirectoryDisplay(remoteOrLocalTargetDirectory: nil, macLocalWorkingDirectory: nil),
            "未选择目标目录"
        )
    }

    // MARK: - Send/Stop 状态机

    func testSendStopStateMachine() {
        // Idle → Send 可用、Stop 不可用
        XCTAssertTrue(AgentComposerRunStateMachine.sendAvailable(phase: .idle))
        XCTAssertFalse(AgentComposerRunStateMachine.stopAvailable(phase: .idle))
        // 已启动的非终态 → 同一个主操作键切换为 Stop。
        for phase in [ComposerRunPhase.preparing, .waitingForCapacity, .startingRuntime,
                      .streaming, .toolProposed, .executingTool, .pausing, .paused,
                      .awaitingUser, .awaitingApproval, .takeoverPending] {
            XCTAssertTrue(AgentComposerRunStateMachine.stopAvailable(phase: phase), "\(phase.rawValue) 显示 Stop")
            XCTAssertTrue(AgentComposerRunStateMachine.sendAvailable(phase: phase), "\(phase.rawValue) 仍允许显式排队入口")
        }
        // Stopping 保留 Stop 图标但禁用重复停止与新提交。
        XCTAssertTrue(AgentComposerRunStateMachine.stopAvailable(phase: .stopping))
        XCTAssertFalse(AgentComposerRunStateMachine.sendAvailable(phase: .stopping))
        // 非活动相位 → Stop 隐藏。
        for phase in [ComposerRunPhase.editingQueuedItem, .takenOver] {
            XCTAssertFalse(AgentComposerRunStateMachine.stopAvailable(phase: phase), "\(phase.rawValue) 不显示 Stop")
            XCTAssertTrue(AgentComposerRunStateMachine.sendAvailable(phase: phase))
        }
        // 关闭集合 15 态
        XCTAssertEqual(ComposerRunPhase.allCases.count, 15)
    }

    @MainActor
    func testAwaitingApprovalSwitchesPrimaryActionToStop() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()

        composer.setRunPhase(.awaitingApproval)

        XCTAssertTrue(composer.isStopVisible, "审批等待仍是可停止的活动 Turn")
        XCTAssertFalse(composer.isIndependentStopVisibleForTesting, "Native 会话不显示第二个停止按钮")
        XCTAssertEqual(composer.primaryActionButtonCountForTesting, 1, "运行态仍只有一个主操作键")
        XCTAssertEqual(composer.primaryActionAccessibilityLabelForTesting, "停止当前任务")
    }

    @MainActor
    func testSendKeyModeRemainsOwnedByTextView() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()

        composer.sendKeyMode = .commandReturnSends

        XCTAssertEqual(composer.textView.sendKeyMode, .commandReturnSends)
        XCTAssertEqual(
            composer.sendButtonKeyEquivalentForTesting,
            "",
            "AppKit 默认按钮不能绕过文本框的 sendKeyMode/IME 路由"
        )
    }

    @MainActor
    func testEscapeIsForwardedToOwningTransientUIHandler() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        var escapeCount = 0
        composer.onEscape = { escapeCount += 1 }

        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeEscape)

        XCTAssertEqual(escapeCount, 1)
    }

    @MainActor
    func testProgrammaticDraftUpdatesSendStateAndNotification() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        var drafts: [String] = []
        composer.onDraftChange = { drafts.append($0) }

        XCTAssertFalse(composer.isSendEnabledForTesting)
        XCTAssertEqual(composer.primaryActionAccessibilityLabelForTesting, "发送")
        composer.setText("从队列拉回的输入")
        XCTAssertTrue(composer.isSendEnabledForTesting)
        XCTAssertEqual(drafts, ["从队列拉回的输入"])

        composer.clearIfUnchanged("从队列拉回的输入")
        XCTAssertFalse(composer.isSendEnabledForTesting)
        XCTAssertEqual(drafts, ["从队列拉回的输入", ""])
    }

    @MainActor
    func testHistoryNavigationPublishesDraftAndEnablesSend() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        var drafts: [String] = []
        composer.onDraftChange = { drafts.append($0) }
        composer.textView.historyProvider = { ["上一条命令"] }

        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeUp)

        XCTAssertEqual(composer.text, "上一条命令")
        XCTAssertTrue(composer.isSendEnabledForTesting)
        XCTAssertEqual(drafts.last, "上一条命令")
    }

    @MainActor
    func testPendingRuntimeSelectionCannotBeBypassedByTypingOrReturn() async throws {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        composer.setRuntimeOptions(
            [
                ComposerRuntimeOption(id: "native", title: "Native"),
                ComposerRuntimeOption(id: "local-agent:test", title: "Stacio Agent")
            ],
            selectedID: "native"
        )
        var completion: ((Bool) -> Void)?
        composer.onRuntimeSelectionRequest = { _, callback in completion = callback }
        var submitted = 0
        composer.onSubmit = { _ in submitted += 1; return true }
        composer.setText("切换前")

        let popup = try XCTUnwrap(
            composerDescendant(
                of: composer.view,
                accessibilityIdentifier: "Stacio.AI.composer.runtime"
            ) as? NSPopUpButton
        )
        popup.selectItem(at: 1)
        _ = NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup)
        XCTAssertFalse(composer.isSendEnabledForTesting)

        composer.setText("切换期间继续输入")
        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        XCTAssertFalse(composer.isSendEnabledForTesting, "文本变化不能绕过尚未落盘的 Runtime 选择")
        XCTAssertEqual(submitted, 0, "Return 也必须服从同一个提交门")

        completion?(true)
        await Task.yield()
        XCTAssertTrue(composer.isSendEnabledForTesting)
    }

    @MainActor
    func testSubmissionLatchPreventsDuplicateAndPreservesNewTyping() async {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        composer.setText("同一条请求")
        let started = expectation(description: "submission started")
        let release = AsyncTestGate()
        var submitted: [String] = []
        composer.onSubmit = { text in
            submitted.append(text)
            started.fulfill()
            await release.wait()
            return true
        }

        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(composer.isSubmissionRequestInFlightForTesting)
        XCTAssertTrue(composer.isSendEnabledForTesting, "提交期间主操作键切换为 Stop")
        XCTAssertEqual(composer.primaryActionAccessibilityLabelForTesting, "停止当前任务")

        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        composer.setText("提交期间继续输入")
        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        XCTAssertEqual(submitted, ["同一条请求"])

        await release.open()
        for _ in 0..<20 where composer.isSubmissionRequestInFlightForTesting {
            await Task.yield()
        }
        XCTAssertFalse(composer.isSubmissionRequestInFlightForTesting)
        XCTAssertEqual(composer.text, "提交期间继续输入")
        XCTAssertTrue(composer.isSendEnabledForTesting)
    }

    @MainActor
    func testStopDuringSubmissionIsLatchedAndDeliveredOnceAfterAcceptance() async {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        composer.setText("持续检查负载")
        let started = expectation(description: "submission started")
        let release = AsyncTestGate()
        var stopCount = 0
        composer.onStop = { stopCount += 1 }
        composer.onSubmit = { _ in
            started.fulfill()
            await release.wait()
            return true
        }

        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(composer.primaryActionAccessibilityLabelForTesting, "停止当前任务")

        let primary = try! XCTUnwrap(
            composerDescendant(
                of: composer.view,
                accessibilityIdentifier: "Stacio.AI.composer.send"
            ) as? NSButton
        )
        primary.performClick(nil)
        primary.performClick(nil)
        XCTAssertEqual(stopCount, 0, "提交未落盘前只锁存停止意图")
        XCTAssertFalse(composer.isSendEnabledForTesting, "停止请求锁存后禁用重复点击")

        await release.open()
        for _ in 0..<20 where composer.isSubmissionRequestInFlightForTesting {
            await Task.yield()
        }
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testQueuePullRequiresEmptyDraftAndFreezesKeyboardSubmission() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        composer.setText("未发送内容")
        XCTAssertNil(composer.beginQueuePull())
        XCTAssertFalse(composer.isQueuePullInProgressForTesting)

        composer.setText("")
        let expectedDraft = composer.beginQueuePull()
        XCTAssertEqual(expectedDraft, "")
        XCTAssertTrue(composer.isQueuePullInProgressForTesting)
        XCTAssertFalse(composer.textView.isEditable)

        var submitted = 0
        composer.onSubmit = { _ in submitted += 1; return true }
        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        XCTAssertEqual(submitted, 0)

        composer.finishQueuePull(with: "拉回后的内容")
        XCTAssertEqual(composer.text, "拉回后的内容")
        XCTAssertTrue(composer.textView.isEditable)
        XCTAssertTrue(composer.isSendEnabledForTesting)
    }

    @MainActor
    func testAskExecutionChoiceBlocksButtonReturnAndExplicitQueue() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        composer.setExecutionChoice(.ask)
        composer.setText("检查磁盘")
        var submitted = 0
        var queued = 0
        composer.onSubmit = { _ in submitted += 1; return true }
        composer.onExplicitQueue = { _ in queued += 1; return true }

        XCTAssertFalse(composer.isSendEnabledForTesting)
        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        composer.textView.handleKeyForTesting(
            keyCode: AgentComposerKeyRouter.keyCodeReturn,
            modifiers: .option
        )

        XCTAssertEqual(submitted, 0)
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(composer.text, "检查磁盘")
    }

    @MainActor
    func testUnavailableLocalAgentCannotEnableSubmission() {
        let composer = AgentComposerViewController()
        composer.loadViewIfNeeded()
        composer.setTerminalPassthroughState(
            runtimeName: "配置不可用",
            isAvailable: false
        )
        composer.setText("不得发送")
        var submitted = 0
        composer.onSubmit = { _ in submitted += 1; return true }

        XCTAssertFalse(composer.isSendEnabledForTesting)
        composer.textView.handleKeyForTesting(keyCode: AgentComposerKeyRouter.keyCodeReturn)
        XCTAssertEqual(submitted, 0)
    }
}

private actor AsyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func composerDescendant(
    of root: NSView,
    accessibilityIdentifier: String
) -> NSView? {
    if root.accessibilityIdentifier() == accessibilityIdentifier { return root }
    for child in root.subviews {
        if let match = composerDescendant(
            of: child,
            accessibilityIdentifier: accessibilityIdentifier
        ) {
            return match
        }
    }
    return nil
}
