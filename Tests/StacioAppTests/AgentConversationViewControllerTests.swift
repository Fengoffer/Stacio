import XCTest
import AppKit
import Foundation
@testable import StacioApp

/// P5-6：AgentConversationViewController（会话壳装配、跨窗口同 Actor、控制状态驱动切换）。
@MainActor
final class AgentConversationViewControllerTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTargetBinding() -> TargetBinding {
        TargetBinding(
            id: "tb-1", revision: 1, digest: "d1", connectionID: "conn-1",
            connectionKind: "ssh", remoteIdentity: "user@host", hostKeyFingerprint: "fp",
            host: "host", user: "user", port: 22, targetWorkingDirectory: "~"
        )
    }

    private func makeState() -> ConversationSessionState {
        let session = ConversationSession(
            id: "c-1", title: "t", createdAt: Self.fixedDate, updatedAt: Self.fixedDate,
            targetBinding: makeTargetBinding(),
            runtimeSelection: AgentRuntimeSelection(kind: .nativeAPI, providerConfigurationID: "pc-1")
        )
        return ConversationSessionState(session: session, lastAppliedSequence: 0)
    }

    // MARK: - 壳可装配

    func testShellAssembledWithComposerTimelineToolbar() {
        let controller = AgentConversationViewController(sessionID: "c-1")
        controller.assemble(
            composer: NSView(),
            timelinePlaceholder: NSView(),
            toolbarPlaceholder: NSView()
        )
        XCTAssertTrue(controller.hasAssembledParts(), "V2 会话壳可被装配（Composer/时间线/工具栏占位）")
        // Review 回归：部件必须实际挂载到 view（否则 V2 壳显示为空白）
        XCTAssertTrue(controller.view.subviews.contains { $0 is NSStackView }, "装配后部件挂载进 view")
    }

    // MARK: - 跨窗口同 Actor

    func testActorRegistrySameActorAcrossWindows() {
        let registry = ConversationActorRegistry()
        let controller1 = AgentConversationViewController(sessionID: "c-1", registry: registry)
        let controller2 = AgentConversationViewController(sessionID: "c-1", registry: registry)
        let store = InMemoryConversationSessionStoreForTesting()
        let sealing = TestConversationSealingForShell()
        let actor1 = controller1.actor(store: store, sealing: sealing, initialState: makeState())
        let actor2 = controller2.actor(store: store, sealing: sealing, initialState: makeState())
        XCTAssertTrue(actor1 === actor2, "跨窗口同一会话同一 Actor（ConversationActorRegistry）")
        let other = AgentConversationViewController(sessionID: "c-2", registry: registry)
        let actor3 = other.actor(store: store, sealing: sealing, initialState: makeState())
        XCTAssertFalse(actor1 === actor3, "不同会话不同 Actor")
    }

    // MARK: - 控制状态驱动切换（§18.4）

    func testEnabledOpensV2NewTaskEntry() {
        let decision = AgentConversationShellPolicy.switchDecision(controlState: .enabled)
        XCTAssertEqual(decision.newTaskEntryOwner, .v2)
        XCTAssertTrue(decision.v2NewTaskEntryAvailable)
        XCTAssertFalse(decision.v1NewTaskEntryAvailable)
        XCTAssertTrue(decision.v2HistoryAvailable)
    }

    func testDrainingHidesV2NewEntryButHistoryAvailable() {
        let decision = AgentConversationShellPolicy.switchDecision(controlState: .draining)
        XCTAssertEqual(decision.newTaskEntryOwner, .v1, "draining 后 V1 拥有新任务执行权")
        XCTAssertFalse(decision.v2NewTaskEntryAvailable, "隐藏/禁用 V2 新执行入口")
        XCTAssertTrue(decision.v2HistoryAvailable, "只读历史可并存")
        XCTAssertTrue(decision.v1NewTaskEntryAvailable)
    }

    func testDisabledKeepsV2ReadOnlyHistoryAndAllowsV1NewEntry() {
        let decision = AgentConversationShellPolicy.switchDecision(controlState: .disabled)
        XCTAssertEqual(decision.newTaskEntryOwner, .v1)
        XCTAssertTrue(decision.v2HistoryAvailable, "disabled 保留 V2 只读历史/排空状态")
        XCTAssertFalse(decision.v2NewTaskEntryAvailable)
        XCTAssertTrue(decision.v1NewTaskEntryAvailable, "允许 V1 新任务入口")
    }

    func testOnlyOneVersionOwnsNewTaskExecutionAtAnyTime() {
        for state in AgentConversationV2ControlState.allCases {
            let decision = AgentConversationShellPolicy.switchDecision(controlState: state)
            let v2Owns = decision.v2NewTaskEntryAvailable
            let v1Owns = decision.v1NewTaskEntryAvailable
            XCTAssertFalse(v2Owns && v1Owns, "\(state.rawValue)：同一时刻只有一个版本拥有新任务执行权")
            XCTAssertTrue(v2Owns || v1Owns, "\(state.rawValue)：总有一个版本可执行新任务")
        }
    }

    func testVersionLabelsDistinct() {
        XCTAssertEqual(AgentConversationShellPolicy.versionLabel(.v2), "V2 会话")
        XCTAssertEqual(AgentConversationShellPolicy.versionLabel(.v1), "V1 会话")
        XCTAssertNotEqual(
            AgentConversationShellPolicy.versionLabel(.v2),
            AgentConversationShellPolicy.versionLabel(.v1),
            "V2/V1 以清晰标签区分"
        )
    }

    // MARK: - 装配点经 Control Coordinator

    func testAssemblyNeverBypassesControlCoordinator() {
        XCTAssertTrue(
            AgentConversationShellPolicy.assemblyMustUseControlCoordinator(),
            "装配点必须经 Control Coordinator（不得绕过直接读 flag 缓存）"
        )
    }

    // MARK: - V1 兼容路径回归

    func testV1CompatiblePathStillRunnable() {
        // V1 面板（AIAssistantPanelViewController）保持可运行：这里验证 V2 壳的存在不破坏 V1 版本枚举
        XCTAssertEqual(ConversationShellVersion.allCases, [.v1, .v2])
        // 阶段 7 收尾前装配默认保留 V1 面板：draining/disabled 均允许 V1
        let draining = AgentConversationShellPolicy.switchDecision(controlState: .draining)
        XCTAssertTrue(draining.v1NewTaskEntryAvailable)
    }
}

// MARK: - 测试 doubles（与 ConversationSessionActorTests 一致的语义）

private final class InMemoryConversationSessionStoreForTesting: ConversationSessionStore {
    var committed: [ConversationCommitBatch] = []
    func load() throws -> ConversationSessionSnapshot {
        ConversationSessionSnapshot(state: nil, lastAppliedSequence: 0)
    }
    func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome {
        committed.append(ConversationCommitBatch(expected: expectedLastSequence, candidates: candidates))
        return .committed(lastSequence: expectedLastSequence + candidates.count)
    }
    func existingEventID(at sequence: Int) -> String? { nil }
    func existingPayloadHash(at sequence: Int) -> String? { nil }
}

private struct ConversationCommitBatch {
    let expected: Int
    let candidates: [ConversationEventEnvelope]
}

private final class TestConversationSealingForShell: ConversationSealing {
    func verifyRoundTrip(payload: Data, aad: String) -> Bool { true }
}
