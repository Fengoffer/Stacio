import Foundation

// MARK: - Local Agent Settings 动作（P4-8）

public enum LocalAgentSettingsActionKind: String, Equatable, Sendable {
    case detect
    case login
    case changeExecutionProfile
    case logout
    case reconcileProcesses
    case openUpgrade
}

/// diagnostic/authentication containment：detect/login 经 `localAgentMaintenanceLaunch`，
/// 零 TargetBinding/workspace/Effect Broker 接触。
public struct LocalAgentContainment: Equatable, Sendable {
    public let targetBindingCount: Int
    public let workspaceCount: Int
    public let effectBrokerCount: Int

    public init(targetBindingCount: Int, workspaceCount: Int, effectBrokerCount: Int) {
        self.targetBindingCount = targetBindingCount
        self.workspaceCount = workspaceCount
        self.effectBrokerCount = effectBrokerCount
    }

    public var isContained: Bool {
        targetBindingCount == 0 && workspaceCount == 0 && effectBrokerCount == 0
    }
}

public enum LocalAgentSettingsAction {

    /// detect/login 经 localAgentMaintenanceLaunch：诊断/认证 containment
    /// （零 TargetBinding/workspace/Effect Broker）。
    public static func containment() -> LocalAgentContainment {
        LocalAgentContainment(targetBindingCount: 0, workspaceCount: 0, effectBrokerCount: 0)
    }

    /// settings process 全局上限 1（复用 P3-10 journal 语义）。
    public static func launchAllowed(activeProcesses: [LocalAgentSettingsProcessState]) -> Bool {
        !LocalAgentSettingsProcessJournal.globalLimitExceeded(activeProcesses: activeProcesses)
    }

    /// 交互登录使用独立可停止 PTY。
    public static func interactiveLoginUsesStopablePTY() -> Bool { true }

    /// 候选路径扫描不写 `executableReference`（扫描只是探测，不落引用）。
    public static func candidateScanWritesExecutableReference() -> Bool { false }

    // MARK: - changeExecutionProfile

    /// 只保存具体 profile/revision（不能只存 kind）。
    public static func profileSpec(profileID: String, revision: Int) -> ExecutionProfileSpec {
        ExecutionProfileSpec(profileID: profileID, revision: revision)
    }

    /// 活动 Attempt 存在时拒绝变更。
    public static func changeExecutionProfileAllowed(hasActiveAttempt: Bool) -> Bool {
        !hasActiveAttempt
    }

    /// PTY trust 记录 descriptor + profile revision + 时间。
    public static func ptyTrustEntry(
        descriptorID: String, profileRevision: Int, trustedAt: Date
    ) -> PTYTrustEntry {
        PTYTrustEntry(descriptorID: descriptorID, profileRevision: profileRevision, trustedAt: trustedAt)
    }

    // MARK: - logout

    /// logout：可 draining/disabled 撤销；先 Stop 再启动（同一全局 slot 的 safety journal）。
    public static func logoutAllowed(controlState: AgentConversationV2ControlState) -> Bool {
        controlState == .draining || controlState == .disabled
    }

    public static func logoutOrder() -> [String] {
        ["stopFirst", "startAfter"]
    }

    // MARK: - reconcileProcesses

    /// 只读采集证据，并以同一 operation ID 结算 `stateUnknown`。
    public static func reconcilePlan(operationID: String) -> ReconcileProcessPlan {
        ReconcileProcessPlan(operationID: operationID, readOnly: true, settlement: "stateUnknown")
    }

    // MARK: - openUpgrade

    /// 只打开已验证官网。
    public static func upgradeURL(verified: Bool, url: URL) -> URL? {
        verified ? url : nil
    }

    // MARK: - OAuth 边界

    /// OAuth 由 CLI 管理；Stacio 不读取/复制/导出/迁移。
    public static func oauthManagedByCLI() -> Bool { true }
    public static func stacioNeverReadsOAuth() -> Bool { true }
    public static func stacioNeverCopiesOAuth() -> Bool { true }
    public static func stacioNeverExportsOAuth() -> Bool { true }
    public static func stacioNeverMigratesOAuth() -> Bool { true }
}

// MARK: - 模型

public struct ExecutionProfileSpec: Equatable, Sendable {
    public let profileID: String
    public let revision: Int

    public init(profileID: String, revision: Int) {
        self.profileID = profileID
        self.revision = revision
    }
}

public struct PTYTrustEntry: Equatable, Sendable {
    public let descriptorID: String
    public let profileRevision: Int
    public let trustedAt: Date

    public init(descriptorID: String, profileRevision: Int, trustedAt: Date) {
        self.descriptorID = descriptorID
        self.profileRevision = profileRevision
        self.trustedAt = trustedAt
    }
}

public struct ReconcileProcessPlan: Equatable, Sendable {
    public let operationID: String
    public let readOnly: Bool
    public let settlement: String

    public init(operationID: String, readOnly: Bool, settlement: String) {
        self.operationID = operationID
        self.readOnly = readOnly
        self.settlement = settlement
    }
}
