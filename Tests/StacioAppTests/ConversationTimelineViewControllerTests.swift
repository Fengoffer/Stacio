import XCTest
import Foundation
import AppKit
@testable import StacioApp

/// P6-2：Conversation Timeline ViewController（diffable、自动跟随、回到最新、分页、锚点、有界缓存）。
final class ConversationTimelineViewControllerTests: XCTestCase {

    // MARK: - 自动跟随

    func testAutoFollowWithin64pt() {
        XCTAssertTrue(ConversationTimelineScroll.shouldAutoFollow(distanceFromBottom: 64), "距底部 ≤64pt 跟随")
        XCTAssertTrue(ConversationTimelineScroll.shouldAutoFollow(distanceFromBottom: 0))
        XCTAssertFalse(ConversationTimelineScroll.shouldAutoFollow(distanceFromBottom: 65), "超过 64pt 不抢滚动位置")
    }

    func testUserScrollUpImmediatelyBreaksFollow() {
        XCTAssertEqual(
            ConversationTimelineScroll.userScrollUpBreaksFollow(scrollingUp: true, current: .following),
            .pausedByUser,
            "用户向上阅读后立即解除"
        )
        XCTAssertEqual(
            ConversationTimelineScroll.userScrollUpBreaksFollow(scrollingUp: false, current: .following),
            .following
        )
        // 已暂停不再改变
        XCTAssertEqual(
            ConversationTimelineScroll.userScrollUpBreaksFollow(scrollingUp: true, current: .pausedByUser),
            .pausedByUser
        )
    }

    func testBackToLatestLabelDoesNotStealScroll() {
        XCTAssertEqual(ConversationTimelineScroll.backToLatestLabel(newItemCount: 3), "回到最新 · 3 条更新")
        // 显示「回到最新 · N 条更新」不抢滚动位置：仅展示按钮，不自动滚动
        XCTAssertTrue(ConversationTimelineScroll.shouldAutoFollow(distanceFromBottom: 200) == false)
    }

    // MARK: - 锚点与滚动位置

    func testAnchorStableWhenExpanding() {
        XCTAssertTrue(ConversationTimelineScroll.anchorStableWhenExpanding(),
                      "展开 Process/Decision/终端块保持可见锚点")
    }

    func testPerSessionScrollPositionRestored() {
        let key1 = ConversationTimelineScroll.scrollPositionKey(sessionID: "c-1")
        let key2 = ConversationTimelineScroll.scrollPositionKey(sessionID: "c-2")
        XCTAssertNotEqual(key1, key2, "切换会话恢复各会话独立滚动位置")
        XCTAssertEqual(key1, "timeline.scrollPosition.c-1")
    }

    // MARK: - 分页

    func testPaginationDefaultPageSize50() {
        XCTAssertEqual(ConversationTimelinePagination.defaultPageSize, 50, "历史每页默认 50 Turn")
        XCTAssertEqual(ConversationTimelinePagination.pagesNeeded(turnCount: 0), 1)
        XCTAssertEqual(ConversationTimelinePagination.pagesNeeded(turnCount: 50), 1)
        XCTAssertEqual(ConversationTimelinePagination.pagesNeeded(turnCount: 51), 2)
        XCTAssertEqual(ConversationTimelinePagination.pagesNeeded(turnCount: 150), 3)
    }

    func testLoadOlderPageAppendsPage() {
        XCTAssertEqual(
            ConversationTimelinePagination.loadedTurnCountAfterLoadOlder(currentLoaded: 50),
            100,
            "向上分页加载更早一页"
        )
    }

    // MARK: - diffable 与有界缓存

    func testUsesDiffableDataSource() {
        XCTAssertTrue(ConversationTimelineDataSource.usesDiffableDataSource(),
                      "diffable data source（不用持续增长 NSStackView 物化整个历史）")
    }

    func testLargeTerminalLogBoundedCache() {
        XCTAssertFalse(ConversationTimelineDataSource.terminalLogRequiresBoundedCache(byteCount: 1024))
        XCTAssertTrue(
            ConversationTimelineDataSource.terminalLogRequiresBoundedCache(
                byteCount: 4 * 1024 * 1024 + 1
            ),
            "大终端日志有界缓存/分页/虚拟化"
        )
    }

    @MainActor
    func testVisibleTimelineRendersMarkdownLinksAndCodeAttributes() throws {
        let controller = ConversationTimelineViewController()
        _ = controller.view
        controller.apply(entries: [
            .finalAnswer("# 结论\n\n访问 [控制台](https://example.com/console)，运行 `status`。"),
            .terminalBlock("$ status\nservice: healthy")
        ])

        let answer = try XCTUnwrap(controller.visibleCellAttributedText(at: 0))
        XCTAssertTrue(answer.string.contains("结论"))
        XCTAssertFalse(answer.string.contains("# 结论"), "标题标记应被渲染而非原样显示")
        let linkRange = (answer.string as NSString).range(of: "控制台")
        XCTAssertEqual(
            answer.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://example.com/console")
        )
        let inlineCodeRange = (answer.string as NSString).range(of: "status")
        let inlineCodeFont = answer.attribute(.font, at: inlineCodeRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(inlineCodeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)

        let terminal = try XCTUnwrap(controller.visibleCellAttributedText(at: 1))
        let terminalFont = terminal.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(terminalFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @MainActor
    func testToolResultIsVisibleInsteadOfDroppingExecutionOutput() {
        let controller = ConversationTimelineViewController()
        _ = controller.view
        controller.apply(entries: [
            .toolCall("执行健康检查", result: "service: healthy")
        ])
        XCTAssertEqual(
            controller.visibleCellText(at: 0),
            "执行健康检查\n\nservice: healthy"
        )
    }

    @MainActor
    func testConversationHierarchyUsesDistinctUserAndAssistantBubbles() throws {
        let controller = ConversationTimelineViewController()
        _ = controller.view
        controller.apply(entries: [
            .userMessage("检查当前服务状态"),
            .finalAnswer("服务状态正常。")
        ])

        let userRow = try XCTUnwrap(controller.visibleCellFrame(at: 0))
        let userSurface = try XCTUnwrap(controller.visibleMessageSurfaceFrameForTesting(at: 0))
        let assistantRow = try XCTUnwrap(controller.visibleCellFrame(at: 1))
        let assistantSurface = try XCTUnwrap(controller.visibleMessageSurfaceFrameForTesting(at: 1))

        XCTAssertEqual(userSurface.maxX, userRow.maxX, accuracy: 1)
        XCTAssertLessThan(userSurface.width, userRow.width)
        XCTAssertEqual(controller.visibleMessageSurfaceBorderWidthForTesting(at: 0), 1)
        XCTAssertEqual(assistantSurface.minX, assistantRow.minX, accuracy: 1)
        XCTAssertEqual(assistantSurface.width, assistantRow.width, accuracy: 1)
        XCTAssertEqual(controller.visibleMessageSurfaceBorderWidthForTesting(at: 1), 1)
    }

    @MainActor
    func testExecutionCardMaterializesAsInteractiveTimelineCell() throws {
        let artifact = TerminalArtifactPresentation(
            requestID: "request-1",
            runtimeID: "runtime-1",
            liveTail: "service: healthy",
            exitCode: 0,
            durationSeconds: 2,
            completionBasis: "agentCompletionMarker",
            stateLabel: "已完成",
            isRealTerminal: true,
            canOpenTerminal: true,
            canCancel: false,
            canSaveRedactedLog: true,
            redactedLog: "[completed] service: healthy"
        )
        let controller = ConversationTimelineViewController()
        var openedRuntimeID: String?
        controller.onOpenTerminal = { openedRuntimeID = $0 }
        controller.apply(entries: [.executionCard(ExecutionCardPresentation(
            proposalID: "proposal-1",
            target: "production",
            targetRuntimeID: "runtime-1",
            workingDirectory: "/srv/app",
            redactedCommand: "status --token [redacted]",
            riskAndApproval: "风险：read-only · 已批准",
            isRealTerminal: true,
            exitCode: 0,
            durationSeconds: 2,
            completionBasis: "agentCompletionMarker",
            status: "已完成",
            terminalArtifact: artifact
        ))])

        let card = try XCTUnwrap(controller.visibleExecutionCardForTesting(at: 0))
        XCTAssertEqual(
            (timelineDescendant(of: card, accessibilityLabel: "脱敏命令") as? NSTextField)?.stringValue,
            "status --token [redacted]"
        )
        XCTAssertEqual(
            (timelineDescendant(of: card, accessibilityLabel: "脱敏终端输出") as? NSTextField)?.stringValue,
            "service: healthy"
        )
        XCTAssertEqual(
            (timelineDescendant(of: card, accessibilityLabel: "脱敏终端输出") as? NSTextField)?.alignment,
            .left
        )
        XCTAssertEqual(
            (timelineDescendant(of: card, accessibilityLabel: "执行元数据") as? NSTextField)?.stringValue,
            "真实终端 · 退出码 0 · 2 秒 · 依据 完成标记"
        )
        let expand = try XCTUnwrap(
            timelineDescendant(of: card, accessibilityLabel: "展开终端输出") as? NSButton
        )
        expand.performClick(nil)
        XCTAssertEqual(
            (timelineDescendant(of: card, accessibilityLabel: "执行详情") as? NSTextField)?.alignment,
            .left
        )
        let open = try XCTUnwrap(
            timelineDescendant(of: card, accessibilityLabel: "在真实终端中查看") as? NSButton
        )
        XCTAssertFalse(open.isHidden)
        open.performClick(nil)
        XCTAssertEqual(openedRuntimeID, "runtime-1")
    }

    @MainActor
    func testCompletedExecutionCardCollapsesCompletelyAndCanBeExpanded() throws {
        let artifact = TerminalArtifactPresentation(
            requestID: "request-1",
            runtimeID: "runtime-1",
            liveTail: "large terminal output",
            exitCode: nil,
            durationSeconds: 2,
            completionBasis: "shellPromptObserved",
            hasTerminalState: true,
            stateLabel: "已完成"
        )
        let presentation = ExecutionCardPresentation(
            proposalID: "proposal-1",
            target: "production",
            workingDirectory: "/srv/app",
            redactedCommand: "top -b -n 1",
            riskAndApproval: "风险：只读 · 已批准",
            isRealTerminal: true,
            exitCode: nil,
            durationSeconds: 2,
            completionBasis: "shellPromptObserved",
            status: "已完成",
            terminalArtifact: artifact
        )
        let controller = ConversationTimelineViewController()
        _ = controller.view
        controller.apply(entries: [.executionCard(presentation)])

        let card = try XCTUnwrap(controller.visibleExecutionCardForTesting(at: 0))
        XCTAssertTrue(card.isCompletelyCollapsedForTesting)
        XCTAssertEqual(
            ExecutionCardView.measuredHeight(for: presentation, expanded: false, width: 500),
            44
        )

        let expand = try XCTUnwrap(
            timelineDescendant(of: card, accessibilityLabel: "展开终端执行") as? NSButton
        )
        expand.performClick(nil)
        XCTAssertFalse(card.isCompletelyCollapsedForTesting)
        XCTAssertFalse(
            (timelineDescendant(of: card, accessibilityLabel: "脱敏命令") as? NSTextField)?.isHidden ?? true
        )
    }

    @MainActor
    func testRunningExecutionExpandedByUserAutoCollapsesWhenItFinishes() throws {
        let runningArtifact = TerminalArtifactPresentation(
            requestID: "request-1",
            runtimeID: "runtime-1",
            liveTail: "sampling",
            exitCode: nil,
            durationSeconds: nil,
            stateLabel: "执行中"
        )
        func presentation(artifact: TerminalArtifactPresentation, status: String) -> ExecutionCardPresentation {
            ExecutionCardPresentation(
                proposalID: "proposal-1",
                target: "production",
                workingDirectory: "/srv/app",
                redactedCommand: "vmstat 1 3",
                riskAndApproval: "风险：只读 · 已批准",
                isRealTerminal: true,
                exitCode: nil,
                durationSeconds: nil,
                completionBasis: "",
                status: status,
                terminalArtifact: artifact
            )
        }

        let controller = ConversationTimelineViewController()
        _ = controller.view
        controller.apply(entries: [.executionCard(presentation(artifact: runningArtifact, status: "执行中"))])
        let runningCard = try XCTUnwrap(controller.visibleExecutionCardForTesting(at: 0))
        let expandOutput = try XCTUnwrap(
            timelineDescendant(of: runningCard, accessibilityLabel: "展开终端输出") as? NSButton
        )
        expandOutput.performClick(nil)

        let finishedArtifact = TerminalArtifactPresentation(
            requestID: "request-1",
            runtimeID: "runtime-1",
            liveTail: "sampling complete",
            exitCode: nil,
            durationSeconds: 3,
            completionBasis: "shellPromptObserved",
            hasTerminalState: true,
            stateLabel: "已完成"
        )
        controller.apply(entries: [.executionCard(presentation(artifact: finishedArtifact, status: "已完成"))])

        let finishedCard = try XCTUnwrap(controller.visibleExecutionCardForTesting(at: 0))
        XCTAssertTrue(finishedCard.isCompletelyCollapsedForTesting)
    }

    @MainActor
    func testTimelineMaterializesLatest50TurnsAndLoadsOlderPage() {
        let controller = ConversationTimelineViewController()
        _ = controller.view
        var entries: [TimelineSourceEntry] = []
        for index in 1...51 {
            entries.append(.userMessage("问题 \(index)"))
            entries.append(.finalAnswer("回答 \(index)"))
        }
        controller.apply(entries: entries)

        XCTAssertTrue(controller.hasOlderEntries)
        XCTAssertEqual(controller.itemCount, 100, "初始只物化最近 50 个 Turn")
        XCTAssertEqual(controller.visibleCellText(at: 0), "问题 2")

        let expandedCount = controller.loadOlderPage()
        XCTAssertEqual(expandedCount, 102)
        XCTAssertFalse(controller.hasOlderEntries)
        XCTAssertEqual(controller.visibleCellText(at: 0), "问题 1")
    }

    @MainActor
    func testStreamingUpdateDoesNotCountSameVisibleItemRepeatedly() {
        let defaults = UserDefaults(suiteName: "timeline-test-\(UUID().uuidString)")!
        let controller = ConversationTimelineViewController(
            sessionID: "streaming",
            scrollPositionDefaults: defaults
        )
        _ = controller.view
        defaults.set(0, forKey: ConversationTimelineScroll.scrollPositionKey(sessionID: "streaming"))
        var entries: [TimelineSourceEntry] = []
        for index in 1...40 {
            entries.append(.userMessage("问题 \(index)"))
            entries.append(.finalAnswer(index == 40 ? "短" : "回答 \(index)"))
        }
        controller.apply(entries: entries)
        XCTAssertEqual(controller.currentFollowState, .pausedByUser)

        entries[79] = .finalAnswer("第一段")
        controller.apply(entries: entries)
        XCTAssertEqual(controller.backToLatestTitleForTesting, "回到最新 · 1 条更新")

        entries[79] = .finalAnswer("第二段")
        controller.apply(entries: entries)
        XCTAssertEqual(controller.backToLatestTitleForTesting, "回到最新 · 1 条更新")
        XCTAssertTrue(controller.backToLatestVisibleForTesting)
    }

    @MainActor
    func testReapplyingPrependedHistoryPreservesExistingEntryIdentity() throws {
        let controller = ConversationTimelineViewController()
        let original: [TimelineSourceEntry] = [
            .userMessage("问题 1"), .finalAnswer("回答 1"),
            .userMessage("问题 2"), .finalAnswer("回答 2"),
            .userMessage("问题 3"), .finalAnswer("回答 3")
        ]
        // `apply` must be safe even when the host has not explicitly loaded
        // the view yet.
        controller.apply(entries: original)
        let originalID = try XCTUnwrap(controller.entryID(at: 2))

        let prepended = [TimelineSourceEntry.userMessage("更早的问题"), .finalAnswer("更早的回答")] + original
        controller.apply(entries: prepended)
        let existingIndex = try XCTUnwrap((0..<controller.itemCount).first {
            controller.visibleCellText(at: $0) == "问题 2"
        })
        XCTAssertEqual(controller.entryID(at: existingIndex), originalID)
    }

    @MainActor
    func testStreamingIdentitySurvivesConcurrentStatusInsertion() throws {
        let controller = ConversationTimelineViewController()
        controller.apply(entries: [
            .userMessage("检查服务"),
            .finalAnswer("第一段"),
            .planProgress("执行中…")
        ])
        let answerID = try XCTUnwrap(controller.entryID(at: 1))
        let statusID = try XCTUnwrap(controller.entryID(at: 2))

        controller.apply(entries: [
            .userMessage("检查服务"),
            .finalAnswer("第一段，继续补充"),
            .planProgress("执行中…"),
            .planProgress("待发送 1 条")
        ])

        XCTAssertEqual(controller.entryID(at: 1), answerID)
        XCTAssertEqual(controller.entryID(at: 2), statusID)
        XCTAssertEqual(controller.visibleCellText(at: 1), "第一段，继续补充")
    }

    @MainActor
    func testExecutingStatusUsesFlowingActivityEffectOnlyWhileActive() throws {
        let controller = ConversationTimelineViewController()
        controller.apply(entries: [
            .planProgress("执行中…"),
            .planProgress("待发送 1 条")
        ])

        XCTAssertEqual(controller.visibleFlowingActivityEffectForTesting(at: 0), true)
        XCTAssertEqual(controller.visibleFlowingActivityEffectForTesting(at: 1), false)

        controller.apply(entries: [.planProgress("已完成")])
        XCTAssertEqual(controller.visibleFlowingActivityEffectForTesting(at: 0), false)
    }

    @MainActor
    func testVisibleTimelineAccessibilityIdentifiesSpeakerAndContent() throws {
        let controller = ConversationTimelineViewController()
        controller.apply(entries: [
            .userMessage("帮我检查服务"),
            .finalAnswer("服务运行正常"),
            .terminalBlock("status: healthy")
        ])

        let user = try XCTUnwrap(controller.visibleCellAccessibilityForTesting(at: 0))
        let answer = try XCTUnwrap(controller.visibleCellAccessibilityForTesting(at: 1))
        let terminal = try XCTUnwrap(controller.visibleCellAccessibilityForTesting(at: 2))
        XCTAssertEqual(user.label, "用户消息")
        XCTAssertEqual(user.value, "帮我检查服务")
        XCTAssertEqual(answer.label, "排查助手回答")
        XCTAssertEqual(answer.value, "服务运行正常")
        XCTAssertEqual(terminal.label, "终端输出")
        XCTAssertEqual(terminal.value, "status: healthy")
    }

    @MainActor
    func testTerminalBlockIsBoundedBeforeMaterialization() {
        let controller = ConversationTimelineViewController()
        _ = controller.view
        let oversized = String(repeating: "输出\n", count: 200_000)
        let boundedEntry = TimelineRow.bounded(entry: .terminalBlock(oversized))
        guard case .terminalBlock(let rendered) = boundedEntry else {
            return XCTFail("terminal block must remain a terminal block")
        }
        XCTAssertLessThanOrEqual(
            Data(rendered.utf8).count,
            ConversationTimelineDataSource.terminalLogDisplayBytes
        )
        XCTAssertTrue(rendered.hasPrefix("[较早终端输出已省略]"))

        controller.apply(entries: [.terminalBlock("$ status\nhealthy")])
        XCTAssertEqual(controller.visibleCellText(at: 0), "$ status\nhealthy")
    }
}

@MainActor
private func timelineDescendant(of root: NSView, accessibilityLabel: String) -> NSView? {
    if root.accessibilityLabel() == accessibilityLabel { return root }
    for child in root.subviews {
        if let match = timelineDescendant(of: child, accessibilityLabel: accessibilityLabel) {
            return match
        }
    }
    return nil
}
