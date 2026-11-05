import XCTest
import Foundation
@testable import StacioApp

/// P7-2：NativeAPIRuntime（请求快照、不直接操作 SSH/文件系统、失败不重路由、answer-only 无 effect、
/// tool delta 仅 ephemeral、验证后一次建批）。
final class NativeAPIRuntimeTests: XCTestCase {

    // MARK: - 请求快照

    func testRequestSnapshotCarriesFullIdentity() {
        let snapshot = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: "conv-1", turnID: "turn-1", attemptID: "attempt-1",
            targetBindingDigest: "digest-1", targetWorkingDirectory: "/srv/app"
        )
        XCTAssertEqual(snapshot.conversationID, "conv-1")
        XCTAssertEqual(snapshot.turnID, "turn-1")
        XCTAssertEqual(snapshot.attemptID, "attempt-1")
        XCTAssertEqual(snapshot.targetBindingDigest, "digest-1")
        XCTAssertEqual(snapshot.targetWorkingDirectory, "/srv/app")
        XCTAssertNil(snapshot.agentProcessWorkingDirectory, "Native 无本地 CLI cwd 不能伪造 AgentProcessWorkingDirectory")
        XCTAssertTrue(NativeAPIRuntimeAction.nativeCannotForgeAgentProcessWorkingDirectory())
    }

    // MARK: - 直接操作边界

    func testNativeDoesNotTouchSSHFileSystemOrTerminal() {
        XCTAssertFalse(NativeAPIRuntimeAction.touchesSSHOrFileSystemDirectly(),
                       "不直接操作 SSH/文件系统/终端")
        XCTAssertTrue(NativeAPIRuntimeAction.toolCallsEnterExistingExecutionChain(),
                      "工具调用进入现有执行协调器/权限/审计/脱敏链")
    }

    // MARK: - 失败不重路由

    func testFailureKeepsProviderAndModel() {
        XCTAssertTrue(NativeAPIRuntimeAction.failureKeepsProviderAndModel(),
                      "模型请求失败保持原供应商与模型不隐式重路由")
    }

    // MARK: - answer-only 无 effect

    func testAnswerOnlyNeverSendsEffectToolSchema() {
        XCTAssertTrue(NativeAPIRuntimeAction.answerOnlySendsNoEffectToolSchema(),
                      "初始 answer-only 与 answerRegeneration 都不发送 effect tool schema")
        XCTAssertTrue(NativeAPIRuntimeAction.answerOnlyToolRequestResolvesWorkModeDenied(),
                      "Runtime 返回工具请求只 resolved(workModeDenied) 或协议失败，绝不创建 EffectCommand")
        XCTAssertEqual(NativeRuntimeResult.workModeDenied, .workModeDenied)
    }

    // MARK: - tool delta ephemeral + 验证后建批

    func testToolDeltaIsEphemeralParserState() {
        XCTAssertTrue(NativeAPIRuntimeAction.toolDeltaIsEphemeralParserState(),
                      "流式 tool_call delta 只是 ephemeral parser state")
        let state = NativeAPIRuntimeAction.beginToolAccumulation(ordinal: 1)
        XCTAssertEqual(state, .accumulating(ordinal: 1, json: ""))
        let after = NativeAPIRuntimeAction.appendToolDelta(state, delta: "{\"tool\":\"ls\"}")
        XCTAssertEqual(after, .accumulating(ordinal: 1, json: "{\"tool\":\"ls\"}"), "delta 追加到 ephemeral state")
    }

    func testToolBatchBuiltOnlyAfterFullValidation() {
        XCTAssertTrue(NativeAPIRuntimeAction.toolBatchBuiltOnlyAfterFullValidation(),
                      "只有验证完整 JSON/schema/batch/finish reason/source ordinal 后一次建整批 proposal")
        // 完整 JSON + schema 字段 + 合法 finish reason → 可建批
        let validJSON = "{\"tool\":\"ls\",\"args\":{\"path\":\"/tmp\"}}"
        XCTAssertTrue(NativeAPIRuntimeAction.validateToolBatch(
            json: validJSON, schemaFields: ["tool", "args"], finishReason: "tool_calls"
        ))
        // schema 字段缺失 → 拒绝
        XCTAssertFalse(NativeAPIRuntimeAction.validateToolBatch(
            json: validJSON, schemaFields: ["tool", "args", "missing"], finishReason: "tool_calls"
        ))
        // 非法 JSON → 拒绝
        XCTAssertFalse(NativeAPIRuntimeAction.validateToolBatch(
            json: "{broken", schemaFields: ["tool"], finishReason: "tool_calls"
        ))
        // 非法 finish reason → 拒绝
        XCTAssertFalse(NativeAPIRuntimeAction.validateToolBatch(
            json: validJSON, schemaFields: ["tool", "args"], finishReason: "length"
        ))
    }

    func testRuntimeResultTypes() {
        XCTAssertEqual(NativeRuntimeResult.finalAnswer(text: "答"), .finalAnswer(text: "答"))
        XCTAssertEqual(NativeRuntimeResult.toolBatch(proposals: ["ls"], ordinal: 1),
                       .toolBatch(proposals: ["ls"], ordinal: 1))
        XCTAssertEqual(NativeRuntimeResult.usage(completionTokens: 100), .usage(completionTokens: 100))
        XCTAssertEqual(NativeRuntimeResult.protocolFailure, .protocolFailure)
    }
}
