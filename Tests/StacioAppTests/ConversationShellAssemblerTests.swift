import XCTest
import AppKit
import Foundation
@testable import StacioApp

/// P7-6：会话壳装配（enabled→V2 壳、draining/disabled→V1 新任务 + V2 只读历史）。
@MainActor
final class ConversationShellAssemblerTests: XCTestCase {

    private func makeV1() -> NSViewController { NSViewController() }
    private func makeV2() -> NSViewController { NSViewController() }

    // MARK: - 控制状态驱动装配

    func testEnabledAssemblesV2Shell() {
        // enabled 时装配 V2 壳（新任务入口）
        var assembledV2 = false
        let result = ConversationShellAssembler.assemble(
            controlState: .enabled,
            makeV1Panel: { NSViewController() },
            makeV2Shell: {
                assembledV2 = true
                return NSViewController()
            },
            makeV2ReadOnlyHistory: { NSViewController() }
        )
        XCTAssertTrue(assembledV2, "enabled 开放 V2 会话壳新任务入口")
        XCTAssertNotNil(result)
    }

    func testDrainingAndDisabledAssembleCompatibilitySurface() {
        for state in [AgentConversationV2ControlState.draining, .disabled] {
            var assembledV1 = false
            var assembledHistory = false
            let result = ConversationShellAssembler.assemble(
                controlState: state,
                makeV1Panel: {
                    assembledV1 = true
                    return NSViewController()
                },
                makeV2Shell: { NSViewController() },
                makeV2ReadOnlyHistory: {
                    assembledHistory = true
                    return NSViewController()
                }
            )
            XCTAssertTrue(assembledV1, "\(state.rawValue) 装配 V1 面板（新任务入口）")
            XCTAssertTrue(assembledHistory, "\(state.rawValue) 必须同时装配 V2 只读历史")
            XCTAssertTrue(result is ConversationCompatibilityViewController)
        }
    }

    func testAssemblyForDecision() {
        XCTAssertEqual(
            ConversationShellAssemblyChoice.assembly(for: ConversationShellSwitchDecision(
                newTaskEntryOwner: .v2, v2HistoryAvailable: true,
                v2NewTaskEntryAvailable: true, v1NewTaskEntryAvailable: false
            )),
            .v2Shell
        )
        XCTAssertEqual(
            ConversationShellAssemblyChoice.assembly(for: ConversationShellSwitchDecision(
                newTaskEntryOwner: .v1, v2HistoryAvailable: true,
                v2NewTaskEntryAvailable: false, v1NewTaskEntryAvailable: true
            )),
            .compatibility,
            "draining/disabled 时 V1 拥有新任务执行权且 V2 历史并存"
        )
    }

    // MARK: - 控制面不可读 fail-safe

    func testUnknownControlStateFallsBackToV1() {
        var assembledV1 = false
        let result = ConversationShellAssembler.assemble(
            controlState: nil,
            makeV1Panel: {
                assembledV1 = true
                return NSViewController()
            },
            makeV2Shell: { NSViewController() },
            makeV2ReadOnlyHistory: { NSViewController() }
        )
        XCTAssertTrue(assembledV1, "控制面不可读 fail-safe 装配 V1")
        XCTAssertNotNil(result)
    }

    // MARK: - 清晰标签

    func testVersionLabelsDistinct() {
        XCTAssertEqual(ConversationShellAssembler.versionLabel(.v2), "V2 会话")
        XCTAssertEqual(ConversationShellAssembler.versionLabel(.v1), "V1 会话")
        XCTAssertNotEqual(
            ConversationShellAssembler.versionLabel(.v2),
            ConversationShellAssembler.versionLabel(.v1)
        )
    }

    @MainActor
    func testCompatibilitySurfaceDefaultsToV1AndCanRevealV2History() throws {
        let v1 = NSViewController()
        let history = NSViewController()
        let controller = ConversationCompatibilityViewController(v1Panel: v1, v2History: history)
        controller.loadView()

        XCTAssertEqual(controller.selectedVersion, .v1)
        XCTAssertNotNil(v1.view.superview)

        controller.selectVersion(.v2)

        XCTAssertEqual(controller.selectedVersion, .v2)
        XCTAssertNil(v1.view.superview)
        XCTAssertNotNil(history.view.superview)
        XCTAssertTrue(history.view.subviews.isEmpty)
    }

    // MARK: - V1 兼容路径回归

    func testV1CompatiblePathStillRunnable() {
        // V1 面板在 draining/disabled 下装配（V1 新任务入口 + V2 只读历史并存）
        let draining = AgentConversationShellPolicy.switchDecision(controlState: .draining)
        XCTAssertEqual(ConversationShellAssemblyChoice.assembly(for: draining), .compatibility)
        XCTAssertTrue(draining.v2HistoryAvailable, "V2 只读历史可并存")
    }
}
