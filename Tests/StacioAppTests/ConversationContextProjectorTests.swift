import XCTest
import Foundation
@testable import StacioApp

/// C2-10：Context Projector 白名单（规格 §15.3）。
///
/// 仅允许：系统/安全策略、InstructionSnapshot、目标结构化信息、用户消息与最终答案、
/// Decision 有效回答、已批准工具结果摘要、显式附件、计划状态、用户确认记忆；
/// 排除：UI 状态、未发送队列、未批准命令、隐藏思维链、完整终端滚动历史、敏感输入、其他分支/主机内容。
final class ConversationContextProjectorTests: XCTestCase {

    private func item(_ kind: ContextProjectionItemKind) -> ContextProjectionItem {
        ContextProjectionItem(kind: kind, content: "content-\(kind.rawValue)", source: "test")
    }

    func testAllowlistPermitsOnlyWhitelistedKinds() {
        let allowed: [ContextProjectionItemKind] = [
            .systemPolicy,
            .instructionSnapshot,
            .targetInfo,
            .userMessage,
            .finalAnswer,
            .decisionAnswer,
            .approvedToolResultSummary,
            .explicitAttachment,
            .planState,
            .userConfirmedMemory
        ]
        for kind in allowed {
            XCTAssertEqual(
                ConversationContextProjector.allowance(for: item(kind)),
                .allowed,
                "\(kind) 应在白名单"
            )
        }
    }

    func testExcludedKindsRejected() {
        let excluded: [ContextProjectionItemKind] = [
            .uiState,
            .unsentQueue,
            .unapprovedCommand,
            .hiddenChainOfThought,
            .terminalScrollback,
            .sensitiveInput,
            .otherBranchContent,
            .otherHostContent
        ]
        for kind in excluded {
            XCTAssertEqual(
                ConversationContextProjector.allowance(for: item(kind)),
                .excluded(reason: "白名单外"),
                "\(kind) 必须排除"
            )
        }
    }

    func testProjectFiltersExcludedItems() {
        let request = ContextProjectionRequest(
            conversationID: "c-1",
            items: [
                item(.userMessage),
                item(.sensitiveInput),
                item(.hiddenChainOfThought),
                item(.finalAnswer),
                item(.terminalScrollback)
            ]
        )
        let projected = ConversationContextProjector.project(request: request)
        XCTAssertEqual(projected.map(\.kind), [.userMessage, .finalAnswer], "投影只保留白名单项")
    }

    func testUnapprovedCommandNeverEnterContext() {
        // 未批准命令不能进入模型上下文（即使它存在于 UI/队列）
        XCTAssertEqual(
            ConversationContextProjector.allowance(for: item(.unapprovedCommand)),
            .excluded(reason: "白名单外")
        )
    }
}
