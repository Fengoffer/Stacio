import XCTest
import Foundation
@testable import StacioApp

/// P9-2：项目记忆（会话记忆只服务当前会话、项目记忆默认关、双身份隔离、确认流、敏感内容、全局记忆禁止、关闭保留）。
final class ProjectMemoryStoreTests: XCTestCase {

    // MARK: - 会话 vs 项目记忆

    func testSessionMemoryOnlyCurrentSession() {
        XCTAssertTrue(ProjectMemoryAction.sessionMemoryServesOnlyCurrentSession(),
                      "会话记忆自动存在只服务当前会话")
        XCTAssertTrue(ProjectMemoryAction.projectMemoryDefaultOff(),
                      "项目记忆默认关闭由用户显式启用/查看/编辑/删除")
    }

    // MARK: - 双身份隔离

    func testIsolationByProjectAndRemoteTarget() {
        XCTAssertTrue(ProjectMemoryAction.isolatedByProjectAndRemoteTargetIdentity(),
                      "按项目身份 + 远程目标身份共同隔离")
        XCTAssertTrue(ProjectMemoryAction.hostDisplayNameAloneInsufficient(),
                      "不能只按主机显示名匹配")
        let identity = ProjectMemoryIdentity(projectIdentity: "stacio", remoteTargetIdentityDigest: "digest-1")
        XCTAssertEqual(identity.projectIdentity, "stacio")
        XCTAssertEqual(identity.remoteTargetIdentityDigest, "digest-1", "远程目标身份是 digest 不是显示名")
        // 不同远程目标 → 不同记忆条目
        let other = ProjectMemoryIdentity(projectIdentity: "stacio", remoteTargetIdentityDigest: "digest-2")
        XCTAssertNotEqual(identity, other)
    }

    // MARK: - 确认流

    func testAgentSuggestionRequiresConfirmation() {
        XCTAssertTrue(ProjectMemoryAction.agentSuggestionRequiresConfirmation(),
                      "Agent 建议写入项目记忆必须请求确认")
    }

    // MARK: - 敏感内容禁止

    func testSecretsNeverEnterMemory() {
        XCTAssertTrue(ProjectMemoryAction.neverInMemory("password=abc"))
        XCTAssertTrue(ProjectMemoryAction.neverInMemory("token sk-xxx"))
        XCTAssertTrue(ProjectMemoryAction.neverInMemory("内部地址 10.0.0.5"))
        XCTAssertTrue(ProjectMemoryAction.neverInMemory("验证码 123456"))
        XCTAssertTrue(ProjectMemoryAction.neverInMemory("secureInput 内容"))
        XCTAssertFalse(ProjectMemoryAction.neverInMemory("部署流程：先 build 再 deploy"))
    }

    // MARK: - 全局记忆禁止

    func testNoGlobalCrossHostAutoMemory() {
        XCTAssertTrue(ProjectMemoryAction.noGlobalCrossHostAutoMemory(),
                      "不建立跨所有主机全局自动记忆")
    }

    // MARK: - 关闭保留

    func testDisabledStopsReadWriteButKeepsExisting() {
        XCTAssertTrue(ProjectMemoryAction.disabledStopsReadWriteButKeepsExistingMemory(),
                      "assistant.memory.projectEnabled 关闭停止读写不自动删除既有记忆")
    }
}
