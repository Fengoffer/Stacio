import Foundation

// MARK: - Local Agent 配置证据投影（P8-7）

/// 证据来源：只读投影方（用户不能手动标记通过）。
public enum LocalAgentEvidenceSource: String, Equatable, Sendable {
    case descriptorProbe
    case maintenanceLaunchJournal
    case evidenceStore
    case capabilityBroker
    case processSupervisor
    case userSelection
}

public enum LocalAgentEvidenceAction {

    /// `detectedVersion/loginStateSummary/lastNegotiatedProtocol/modelSelectionMode/discoveredModels`
    /// 只由 descriptor probe / localAgentMaintenanceLaunch journal 与 Evidence Store 只读投影。
    public static func projectedOnlyByProbeOrJournal(_ field: String) -> Bool {
        switch field {
        case "detectedVersion", "loginStateSummary", "lastNegotiatedProtocol",
             "modelSelectionMode", "discoveredModels":
            return true
        default:
            return false
        }
    }

    /// `containmentProfileID/containmentRevision/launchCapabilityBindingRevision/
    /// answerOnlyContainmentRevision/capabilitySnapshot/environmentDigest/bypassTestedAt/
    /// lastVerifiedAt/state` 只由 Broker/Supervisor/证据 Store 投影。
    public static func projectedOnlyByBrokerSupervisorOrEvidenceStore(_ field: String) -> Bool {
        switch field {
        case "containmentProfileID", "containmentRevision", "launchCapabilityBindingRevision",
             "answerOnlyContainmentRevision", "capabilitySnapshot", "environmentDigest",
             "bypassTestedAt", "lastVerifiedAt", "state":
            return true
        default:
            return false
        }
    }

    /// 用户不能手动标记通过。
    public static func userCannotManuallyMarkVerified() -> Bool { true }

    /// `localAgent.changeExecutionProfile` 只能提交选择和显式 PTY trust，不得写验证结果。
    public static func changeProfileWritesOnlySelectionAndExplicitPTYTrust() -> Bool { true }

    /// 配置或 descriptor 更新后重新记录版本/能力/登录状态/最后验证时间/environment digest/
    /// containment profile revision/capability-binding revision/process-supervision revision。
    public static func revalidateAfterConfigurationOrDescriptorUpdate() -> Bool { true }

    /// 证据来源必须是只读投影方（userSelection 不能产生验证证据）。
    public static func sourceProducesVerificationEvidence(_ source: LocalAgentEvidenceSource) -> Bool {
        switch source {
        case .descriptorProbe, .maintenanceLaunchJournal, .evidenceStore,
             .capabilityBroker, .processSupervisor:
            return true
        case .userSelection:
            return false
        }
    }
}
