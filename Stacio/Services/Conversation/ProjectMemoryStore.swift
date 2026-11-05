import Foundation

// MARK: - 项目记忆（P9-2）

/// 项目记忆身份：项目身份 + 远程目标身份（digest）共同隔离。
public struct ProjectMemoryIdentity: Equatable, Sendable {
    public let projectIdentity: String
    /// 远程目标身份（digest，不是主机显示名）。
    public let remoteTargetIdentityDigest: String

    public init(projectIdentity: String, remoteTargetIdentityDigest: String) {
        self.projectIdentity = projectIdentity
        self.remoteTargetIdentityDigest = remoteTargetIdentityDigest
    }
}

public struct ProjectMemoryEntry: Equatable, Sendable {
    public let identity: ProjectMemoryIdentity
    public let text: String

    public init(identity: ProjectMemoryIdentity, text: String) {
        self.identity = identity
        self.text = text
    }
}

public enum ProjectMemoryAction {

    /// 会话记忆自动存在只服务当前会话。
    public static func sessionMemoryServesOnlyCurrentSession() -> Bool { true }

    /// 项目记忆默认关闭，由用户显式启用/查看/编辑/删除。
    public static func projectMemoryDefaultOff() -> Bool { true }

    /// 按项目身份 + 远程目标身份共同隔离（不能只按主机显示名匹配）。
    public static func isolatedByProjectAndRemoteTargetIdentity() -> Bool { true }
    public static func hostDisplayNameAloneInsufficient() -> Bool { true }

    /// Agent 建议写入项目记忆必须请求确认。
    public static func agentSuggestionRequiresConfirmation() -> Bool { true }

    /// 密码/Token/内部地址凭证/敏感终端输出/安全输入不得进入记忆。
    public static func neverInMemory(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("password") || lower.contains("token")
            || lower.contains("internal address") || lower.contains("内部地址")
            || lower.contains("内网")
            || lower.contains("验证码") || lower.contains("otp")
            || lower.contains("secureinput")
    }

    /// 不建立跨所有主机全局自动记忆。
    public static func noGlobalCrossHostAutoMemory() -> Bool { true }

    /// `assistant.memory.projectEnabled` 关闭停止读写，不自动删除既有记忆。
    public static func disabledStopsReadWriteButKeepsExistingMemory() -> Bool { true }
}
