import Foundation

// MARK: - Local Agent Containment Policy（P8-2）

public enum ContainmentStatus: Equatable, Sendable {
    case verified
    case unknown
    case failed
}

/// managed 五维验证结果（任一未知或失效阻止 managed launch）。
public struct ContainmentVerificationResult: Equatable, Sendable {
    public let processIsolation: ContainmentStatus
    public let fileSystemIsolation: ContainmentStatus
    public let networkEgress: ContainmentStatus
    public let toolProxy: ContainmentStatus
    public let launchCapability: ContainmentStatus

    public init(
        processIsolation: ContainmentStatus, fileSystemIsolation: ContainmentStatus,
        networkEgress: ContainmentStatus, toolProxy: ContainmentStatus,
        launchCapability: ContainmentStatus
    ) {
        self.processIsolation = processIsolation
        self.fileSystemIsolation = fileSystemIsolation
        self.networkEgress = networkEgress
        self.toolProxy = toolProxy
        self.launchCapability = launchCapability
    }

    public var allVerified: Bool {
        processIsolation == .verified && fileSystemIsolation == .verified
            && networkEgress == .verified && toolProxy == .verified
            && launchCapability == .verified
    }
}

/// 本地进程目录三选。
public enum LocalWorkingDirectoryMode: String, Codable, CaseIterable, Equatable, Sendable {
    case managedWorkspace
    case userSelectedLocalDirectory
    case askEveryTurn
}

/// PATH 三策略。
public enum LocalAgentPathPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case controlled
    case loginShell
    case explicitList
}

public enum LocalAgentContainmentPolicy {

    /// OS 可强制的进程/文件系统/网络边界（不是提示词约束）。
    public static func osEnforceableBoundaries() -> Bool { true }

    /// PATH、环境白名单、提示词、AGENTS.md、CLI 自带审批不能替代 containment。
    public static func softControlsCannotReplaceContainment() -> Bool { true }

    /// AgentProcessWorkingDirectory 只接受已验证 Mac 本地引用；
    /// 远程 targetWorkingDirectory 不能传给 Mac chdir。
    public static func workingDirectoryRequiresVerifiedLocalReference() -> Bool { true }
    public static func remoteTargetWorkingDirectoryCannotPassToMacChdir() -> Bool { true }

    /// 目录不可用时暂停，不回退 Home/tmp/仓库根。
    public static func unavailableDirectoryPausesInsteadOfFallback() -> Bool { true }

    /// 环境白名单默认 `LANG,LC_*,TERM,TMPDIR` + descriptor 必需项。
    public static let defaultEnvWhitelist: [String] = ["LANG", "LC_*", "TERM", "TMPDIR"]

    public static func envWhitelistAllows(_ key: String, descriptorRequiredKeys: Set<String>) -> Bool {
        if descriptorRequiredKeys.contains(key) { return true }
        return defaultEnvWhitelist.contains { pattern in
            if pattern.hasSuffix("*") {
                return key.hasPrefix(String(pattern.dropLast()))
            }
            return key == pattern
        }
    }

    /// OAuth/SSH/Keychain/代理密码变量永远拒绝。
    public static func envAlwaysRejected(_ key: String) -> Bool {
        let upper = key.uppercased()
        return upper.contains("OAUTH") || upper.contains("SSH_") || upper.contains("KEYCHAIN")
            || upper.contains("PROXY") && upper.contains("PASS")
            || upper.contains("TOKEN")
    }

    /// managed 详情分别显示进程/文件系统/网络/工具代理/launch capability 验证结果；
    /// 任一未知或失效阻止 managed launch。
    public static func managedLaunchAllowed(_ verification: ContainmentVerificationResult) -> Bool {
        verification.allVerified
    }
}
