import Foundation

// MARK: - 凭证轮换/吊销/代理/origin-copy 动作（P4-7）

// MARK: rotateCredential

public struct RotationPlan: Equatable, Sendable {
    public let newGenerationID: String
    public let retiredGenerationIDs: [String]
    /// 展示受影响 Attempt/Retry（旧 generation 的引用者）。
    public let affectedAttemptIDs: [String]

    public init(newGenerationID: String, retiredGenerationIDs: [String], affectedAttemptIDs: [String]) {
        self.newGenerationID = newGenerationID
        self.retiredGenerationIDs = retiredGenerationIDs
        self.affectedAttemptIDs = affectedAttemptIDs
    }
}

public enum CredentialRotationAction {

    /// `provider.rotateCredential`：创建新 generation、旧 generation 全部 retired、
    /// 展示受影响 Attempt/Retry。
    public static func planRotation(
        existingGenerationIDs: [String], affectedAttemptIDs: [String]
    ) -> RotationPlan {
        RotationPlan(
            newGenerationID: "gen-\(existingGenerationIDs.count + 1)",
            retiredGenerationIDs: existingGenerationIDs,
            affectedAttemptIDs: affectedAttemptIDs
        )
    }

    /// 受影响 Attempt 展示：仅引用旧 generation 的 Attempt/Retry。
    public static func affectedAttempts(
        referencing generationID: String,
        attemptBindings: [String: String]  // attemptID → generationID
    ) -> [String] {
        attemptBindings.filter { $0.value == generationID }.map(\.key).sorted()
    }
}

// MARK: revokeCredentialNow

public enum RevocationStep: String, Equatable, Sendable {
    /// 先 durable revoke/access fence 关 gate。
    case durableRevokeFence
    /// 再取消引用该 generation 的 Attempt。
    case cancelReferencingAttempts
    /// 本地删除（可能失败 → pendingDeletion）。
    case localDeletion
}

public enum LocalDeletionState: Equatable, Sendable {
    case deleted
    /// 本地删除失败：pendingDeletion + 上游控制台入口（不冒充上游已撤销）。
    case pendingDeletion(upstreamConsoleURL: String)
}

public enum CredentialRevocationAction {

    /// 二次确认：revokeCredentialNow 必须显式确认。
    public static func requiresConfirmation() -> Bool { true }

    /// 顺序固定：先 durable revoke/access fence，再取消引用 Attempt，最后本地删除。
    public static func executionOrder() -> [RevocationStep] {
        [.durableRevokeFence, .cancelReferencingAttempts, .localDeletion]
    }

    /// 本地删除失败 → pendingDeletion + 上游控制台入口；
    /// 不冒充上游已撤销（revoked 状态只能由上游确认，本地只报 pendingDeletion）。
    public static func localDeletionOutcome(
        succeeded: Bool, upstreamConsoleURL: String
    ) -> LocalDeletionState {
        succeeded ? .deleted : .pendingDeletion(upstreamConsoleURL: upstreamConsoleURL)
    }
}

// MARK: saveProxyCredential / clearProxyCredential

public enum ProxyCredentialAction {

    /// 独立 scoped generation：代理凭证与主凭证 generation 命名空间分离。
    public static func scopedGenerationID(proxyID: String) -> String {
        "proxy.\(proxyID)"
    }

    /// 清除走 draining/disabled 继续的安全结算：draining 或 disabled 都允许清除（存量结算）。
    public static func clearAllowed(controlState: AgentConversationV2ControlState) -> Bool {
        controlState == .draining || controlState == .disabled
    }
}

// MARK: copyCredentialToNewOrigin

public struct OriginCopyPlan: Equatable, Sendable {
    public let useLeaseOwner: String
    public let stagingRequired: Bool
    public let newGenerationID: String
    public let originalScopePreserved: Bool
    public let proxyCredentialCopied: Bool

    public init(
        useLeaseOwner: String, stagingRequired: Bool, newGenerationID: String,
        originalScopePreserved: Bool, proxyCredentialCopied: Bool
    ) {
        self.useLeaseOwner = useLeaseOwner
        self.stagingRequired = stagingRequired
        self.newGenerationID = newGenerationID
        self.originalScopePreserved = originalScopePreserved
        self.proxyCredentialCopied = proxyCredentialCopied
    }
}

public enum OriginCopyAction {

    /// `configuration.copyCredentialToNewOrigin`：一次性 `credentialOriginCopy` use lease、
    /// staging、新 item/generation；失败清理；不修改旧 scope；不自动复制代理凭证。
    public static func planCopy(origin: String, hasProxyCredential: Bool) -> OriginCopyPlan {
        OriginCopyPlan(
            useLeaseOwner: "credentialOriginCopy",
            stagingRequired: true,
            newGenerationID: "copy.\(origin)",
            originalScopePreserved: true,
            proxyCredentialCopied: false
        )
    }

    /// 失败清理：staging 删除或 quarantine（目标未提交）。
    public static func cleanupOnFailure(cleanupKind: String) -> Bool {
        cleanupKind == "delete" || cleanupKind == "quarantine"
    }
}
