import XCTest
import Foundation
@testable import StacioApp

/// P6-5：Conversation Sidebar 与 Toolbar（列表字段、状态符号+文字、无跨会话排序、工具栏固定集合、
/// 内联状态条、新建会话 Sheet 顺序与取消清理）。
final class ConversationSidebarTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEntry(
        id: String = "c-1", title: String = "会话", host: String = "host",
        runtime: String = "Native", state: ConversationRunState = .running,
        unread: Bool = false, pinned: Bool = false
    ) -> ConversationListEntry {
        ConversationListEntry(
            sessionID: id, title: title, targetHost: host, runtimeLabel: runtime,
            updatedAt: Self.fixedDate, runState: state, unread: unread, pinned: pinned
        )
    }

    // MARK: - 列表显示字段

    func testListEntryShowsAllFields() {
        let entry = makeEntry(host: "deploy@example.com", runtime: "Kimi", state: .waitingApproval, unread: true)
        XCTAssertEqual(entry.targetHost, "deploy@example.com", "目标主机")
        XCTAssertEqual(entry.runtimeLabel, "Kimi", "Runtime")
        XCTAssertEqual(entry.runState, .waitingApproval, "运行状态")
        XCTAssertTrue(entry.unread, "未读状态")
        XCTAssertEqual(entry.updatedAt, Self.fixedDate, "更新时间")
    }

    // MARK: - 搜索/固定/重命名/归档

    func testSearchMatchesTitleHostRuntime() {
        let entries = [
            makeEntry(id: "1", title: "部署", host: "prod.example", runtime: "Kimi"),
            makeEntry(id: "2", title: "开发", host: "dev.example", runtime: "Codex"),
            makeEntry(id: "3", title: "测试", host: "stage.example", runtime: "Kimi")
        ]
        XCTAssertEqual(ConversationSidebarAction.search(entries, query: "Kimi").map(\.sessionID), ["1", "3"])
        XCTAssertEqual(ConversationSidebarAction.search(entries, query: "dev.example").map(\.sessionID), ["2"])
        XCTAssertEqual(ConversationSidebarAction.search(entries, query: "部署").map(\.sessionID), ["1"])
        XCTAssertEqual(ConversationSidebarAction.search(entries, query: "  ").count, 3, "空查询返回全部")
    }

    func testPinRenameArchiveUnread() {
        let entries = [makeEntry(id: "1"), makeEntry(id: "2")]
        let pinned = ConversationSidebarAction.togglePin(entries, sessionID: "1")
        XCTAssertTrue(pinned.first { $0.sessionID == "1" }?.pinned ?? false, "固定")
        let renamed = ConversationSidebarAction.rename(pinned, sessionID: "1", newTitle: "新标题")
        XCTAssertEqual(renamed.first { $0.sessionID == "1" }?.title, "新标题", "重命名")
        let archived = ConversationSidebarAction.archive(renamed, sessionID: "1")
        XCTAssertEqual(archived.map(\.sessionID), ["2"], "归档")
        let unread = ConversationSidebarAction.markUnread(entries, sessionID: "2", unread: true)
        XCTAssertTrue(unread.first { $0.sessionID == "2" }?.unread ?? false)
    }

    // MARK: - 状态符号与文字

    func testRunStateUsesSystemSymbolAndText() {
        // 每个状态都有系统符号 + 文字（不只依赖颜色）
        for state in ConversationRunState.allCases {
            XCTAssertFalse(state.systemSymbol.isEmpty, "\(state.rawValue) 有系统状态符号")
            XCTAssertFalse(state.displayText.isEmpty, "\(state.rawValue) 有文字")
        }
        XCTAssertEqual(ConversationRunState.running.systemSymbol, "play.circle.fill")
        XCTAssertEqual(ConversationRunState.waitingCapacity.displayText, "等待容量")
        XCTAssertEqual(ConversationRunState.failed.displayText, "失败")
        XCTAssertEqual(ConversationRunState.takenOver.displayText, "已接管")
    }

    // MARK: - 跨会话排序

    func testNoCrossSessionReorder() {
        XCTAssertFalse(ConversationSidebarAction.crossSessionReorderAvailable(),
                      "侧栏不提供跨会话插队或拖动全局顺序")
    }

    // MARK: - 工具栏

    func testToolbarFixedItemSet() {
        XCTAssertEqual(ConversationToolbarAction.toolbarItemIdentifiers(), [
            "sessionTitle", "targetIdentity", "runtimeStatus", "newConversation", "search", "history", "more"
        ])
        XCTAssertTrue(ConversationToolbarAction.identityChangeShowsInlineStatusBar(),
                      "主机/用户/端口/工作目录变化显示内联状态条不用遮挡弹窗")
    }

    @MainActor
    func testToolbarHidesActionsWithoutProductionHandlers() {
        let toolbar = ConversationToolbarViewController()
        _ = toolbar.view
        XCTAssertEqual(toolbar.visibleActionIdentifiersForTesting, [], "未接线动作不得显示假按钮")

        toolbar.onSettings = {}
        XCTAssertEqual(toolbar.visibleActionIdentifiersForTesting, ["more"])
        toolbar.onNewConversation = {}
        XCTAssertEqual(toolbar.visibleActionIdentifiersForTesting, ["newConversation", "more"])
    }

    // MARK: - 新建会话 Sheet

    @MainActor
    func testNewConversationSheetRequiresVerifiedTargetAndRuntime() throws {
        let sheet = NewConversationSheetViewController(
            targets: [NewConversationTargetOption(
                runtimeID: "terminal-1",
                title: "deploy@example.com",
                detail: "ssh · /srv/app",
                isCurrent: true
            )],
            runtimes: [NewConversationRuntimeOption(
                selection: .native(configurationID: "provider-1"),
                title: "Production API",
                modelAccountStatus: "Native API · model-1 · 已验证",
                isVerified: true
            )],
            initialTargetRuntimeID: nil,
            initialRuntimeConfigurationID: nil,
            initialWorkMode: .planFirst,
            initialExecutionChoice: .backgroundVirtualTerminal
        )
        sheet.loadViewIfNeeded()

        XCTAssertFalse(sheet.isCreateEnabledForTesting)
        XCTAssertEqual(sheet.displayedTargetStatusForTesting, "未选择 · 未验证")
        XCTAssertEqual(sheet.displayedRuntimeStatusForTesting, "未选择 · 未验证")

        sheet.selectTargetForTesting(runtimeID: "terminal-1")
        sheet.selectRuntimeForTesting(configurationID: "provider-1")

        XCTAssertTrue(sheet.isCreateEnabledForTesting)
        XCTAssertEqual(sheet.displayedTargetStatusForTesting, "来源：当前终端 · 已验证")
        XCTAssertEqual(sheet.displayedRuntimeStatusForTesting, "来源：配置目录 · 已验证")
        XCTAssertEqual(sheet.displayedModelAccountStatusForTesting, "Native API · model-1 · 已验证")
        XCTAssertEqual(
            try XCTUnwrap(sheet.selectedConfigurationForTesting),
            NewConversationConfiguration(
                targetRuntimeID: "terminal-1",
                runtimeSelection: .native(configurationID: "provider-1"),
                workMode: .planFirst,
                executionChoice: .backgroundVirtualTerminal
            )
        )
    }

    @MainActor
    func testCancelRealSheetDoesNotEmitCreate() {
        let sheet = NewConversationSheetViewController(
            targets: [NewConversationTargetOption(runtimeID: "terminal-1", title: "Local")],
            runtimes: [NewConversationRuntimeOption(
                selection: .native(configurationID: "provider-1"),
                title: "API",
                modelAccountStatus: "已验证",
                isVerified: true
            )],
            initialTargetRuntimeID: "terminal-1",
            initialRuntimeConfigurationID: "provider-1",
            initialWorkMode: .agent,
            initialExecutionChoice: .realTerminal
        )
        var created = false
        var cancelled = false
        sheet.onCreate = { _ in created = true }
        sheet.onCancel = { cancelled = true }
        sheet.loadViewIfNeeded()

        sheet.cancelForTesting()

        XCTAssertTrue(cancelled)
        XCTAssertFalse(created)
    }

    @MainActor
    func testLocalAgentSheetForcesTerminalPassthroughContract() throws {
        let sheet = NewConversationSheetViewController(
            targets: [NewConversationTargetOption(runtimeID: "terminal-1", title: "Local")],
            runtimes: [NewConversationRuntimeOption(
                selection: .localAgent(configurationID: "codex-1"),
                title: "Codex",
                modelAccountStatus: "CLI 登录 · 已验证",
                isVerified: true
            )],
            initialTargetRuntimeID: "terminal-1",
            initialRuntimeConfigurationID: "codex-1",
            initialWorkMode: .answerOnly,
            initialExecutionChoice: .backgroundVirtualTerminal
        )
        sheet.loadViewIfNeeded()

        let result = try XCTUnwrap(sheet.selectedConfigurationForTesting)
        XCTAssertEqual(result.workMode, .agent)
        XCTAssertEqual(result.executionChoice, .realTerminal)
    }
}
