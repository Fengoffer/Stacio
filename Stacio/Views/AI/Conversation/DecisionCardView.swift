import Foundation

// MARK: - Decision Card（P6-4）

/// Decision Card 展示（不可变投影）。
public struct DecisionCardPresentation: Equatable, Sendable {
    public let targetHost: String
    public let targetWorkingDirectory: String
    public let shellOrExecutable: String
    public let argvItems: [String]
    /// 环境变量增量（只显示 key 来源，不显示值正文）。
    public let envDeltaKeys: [String]
    public let stdinSource: String
    public let redirects: [String]
    public let escalationMethod: String?
    public let timeoutSeconds: Int?
    public let impactScope: String
    public let riskLevel: String
    public let targetBindingDigest: String
    public let terminalLeaseGeneration: Int
    public let immutableSummary: String
    /// Local Agent 另列。
    public let localAgentWorkingDirectory: String?
    public let launchContainmentGeneration: String?

    public init(
        targetHost: String, targetWorkingDirectory: String, shellOrExecutable: String,
        argvItems: [String], envDeltaKeys: [String], stdinSource: String,
        redirects: [String], escalationMethod: String?, timeoutSeconds: Int?,
        impactScope: String, riskLevel: String, targetBindingDigest: String,
        terminalLeaseGeneration: Int, immutableSummary: String,
        localAgentWorkingDirectory: String? = nil, launchContainmentGeneration: String? = nil
    ) {
        self.targetHost = targetHost
        self.targetWorkingDirectory = targetWorkingDirectory
        self.shellOrExecutable = shellOrExecutable
        self.argvItems = argvItems
        self.envDeltaKeys = envDeltaKeys
        self.stdinSource = stdinSource
        self.redirects = redirects
        self.escalationMethod = escalationMethod
        self.timeoutSeconds = timeoutSeconds
        self.impactScope = impactScope
        self.riskLevel = riskLevel
        self.targetBindingDigest = targetBindingDigest
        self.terminalLeaseGeneration = terminalLeaseGeneration
        self.immutableSummary = immutableSummary
        self.localAgentWorkingDirectory = localAgentWorkingDirectory
        self.launchContainmentGeneration = launchContainmentGeneration
    }
}

/// 结构化 Change Summary。
public struct ChangeSummaryPresentation: Equatable, Sendable {
    public let target: String
    public let operationType: String
    public let affectedObjects: [String]
    public let beforeHash: String?
    public let afterHash: String?
    public let backupRollbackReference: String?
    public let verificationResult: String?
    public let unverifiedItems: [String]
    /// secret diff 只显示「敏感值已变化」+ hash。
    public let secretDiff: String?

    public init(
        target: String, operationType: String, affectedObjects: [String],
        beforeHash: String?, afterHash: String?, backupRollbackReference: String?,
        verificationResult: String?, unverifiedItems: [String], secretDiff: String? = nil
    ) {
        self.target = target
        self.operationType = operationType
        self.affectedObjects = affectedObjects
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.backupRollbackReference = backupRollbackReference
        self.verificationResult = verificationResult
        self.unverifiedItems = unverifiedItems
        self.secretDiff = secretDiff
    }
}

public enum DecisionCardAction {

    /// 敏感值只显示来源与是否存在，不显示正文。
    public static func sensitiveValueDisplay(source: String, present: Bool) -> String {
        "来源：\(source)（\(present ? "已存在" : "未设置")）"
    }

    /// 多 Tool Call 先显示「工具 1/N」；后续只显示排队摘要。
    public static func toolCallLabel(index: Int, total: Int) -> String {
        "工具 \(index)/\(total)"
    }
    public static func queuedSummaryLabel(remaining: Int) -> String {
        "另有 \(remaining) 个工具调用排队"
    }

    /// secret diff 只显示「敏感值已变化」+ hash（不显示正文 diff）。
    public static func secretDiffDisplay(afterHash: String) -> String {
        "敏感值已变化 · \(afterHash)"
    }
}
