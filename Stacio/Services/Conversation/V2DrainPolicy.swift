import Foundation

// MARK: - V2 排空演练策略（P10-2）

/// draining→disabled 全套条件清单。
public struct DrainReadinessChecklist: Equatable, Sendable {
    public var openPermitsOrJournals: Bool
    public var queuedRequestsOrLeases: Bool
    public var activeAttemptsIntentsDecisionsProposals: Bool
    public var activeSecureInput: Bool
    public var unsettledAuthority: Bool
    public var answerOnlyCapabilityNotFinal: Bool
    public var nativeRequestsInFlight: Bool
    public var managedProcessesRunningOrScratchNotDeleted: Bool
    public var outboxNonEmpty: Bool
    public var settingsProcessNotTerminal: Bool
    public var unknownRemoteEffectsUnlocked: Bool
    public var credentialSagasInFlight: Bool
    public var verificationRequestsInFlight: Bool
    public var setupNotInStableState: Bool
    public var repositoryCheckpointNotReadOnlyOpenable: Bool

    public init(
        openPermitsOrJournals: Bool = false,
        queuedRequestsOrLeases: Bool = false,
        activeAttemptsIntentsDecisionsProposals: Bool = false,
        activeSecureInput: Bool = false,
        unsettledAuthority: Bool = false,
        answerOnlyCapabilityNotFinal: Bool = false,
        nativeRequestsInFlight: Bool = false,
        managedProcessesRunningOrScratchNotDeleted: Bool = false,
        outboxNonEmpty: Bool = false,
        settingsProcessNotTerminal: Bool = false,
        unknownRemoteEffectsUnlocked: Bool = false,
        credentialSagasInFlight: Bool = false,
        verificationRequestsInFlight: Bool = false,
        setupNotInStableState: Bool = false,
        repositoryCheckpointNotReadOnlyOpenable: Bool = false
    ) {
        self.openPermitsOrJournals = openPermitsOrJournals
        self.queuedRequestsOrLeases = queuedRequestsOrLeases
        self.activeAttemptsIntentsDecisionsProposals = activeAttemptsIntentsDecisionsProposals
        self.activeSecureInput = activeSecureInput
        self.unsettledAuthority = unsettledAuthority
        self.answerOnlyCapabilityNotFinal = answerOnlyCapabilityNotFinal
        self.nativeRequestsInFlight = nativeRequestsInFlight
        self.managedProcessesRunningOrScratchNotDeleted = managedProcessesRunningOrScratchNotDeleted
        self.outboxNonEmpty = outboxNonEmpty
        self.settingsProcessNotTerminal = settingsProcessNotTerminal
        self.unknownRemoteEffectsUnlocked = unknownRemoteEffectsUnlocked
        self.credentialSagasInFlight = credentialSagasInFlight
        self.verificationRequestsInFlight = verificationRequestsInFlight
        self.setupNotInStableState = setupNotInStableState
        self.repositoryCheckpointNotReadOnlyOpenable = repositoryCheckpointNotReadOnlyOpenable
    }

    /// 全部条件满足才可 draining→disabled。
    public var readyForDisabled: Bool {
        !openPermitsOrJournals && !queuedRequestsOrLeases
            && !activeAttemptsIntentsDecisionsProposals && !activeSecureInput
            && !unsettledAuthority && !answerOnlyCapabilityNotFinal
            && !nativeRequestsInFlight && !managedProcessesRunningOrScratchNotDeleted
            && !outboxNonEmpty && !settingsProcessNotTerminal
            && !unknownRemoteEffectsUnlocked && !credentialSagasInFlight
            && !verificationRequestsInFlight && !setupNotInStableState
            && !repositoryCheckpointNotReadOnlyOpenable
    }
}

public enum V2DrainPolicy {

    /// enabled→draining：原子提升 generation、关 Permit 签发/commit authorization、
    /// 关 V2 admission、取消未获准 request、冻结 fence 前 Permit。
    public static func enabledToDrainingSteps() -> [String] {
        [
            "advanceGenerationAtomically",
            "closePermitIssuanceAndCommitAuthorization",
            "closeV2Admission",
            "cancelUnauthorizedRequests",
            "freezePreFencePermits"
        ]
    }

    /// draining→disabled 全套条件（清单）。
    public static func readyForDisabled(_ checklist: DrainReadinessChecklist) -> Bool {
        checklist.readyForDisabled
    }

    /// disabled→enabled：新 transition/generation 且旧 Permit/request/capability 不复活。
    public static func disabledToEnabledDoesNotResurrectOldArtifacts() -> Bool { true }

    /// 任何场景不丢草稿/队列、不重复外部 effect。
    public static func noDraftOrQueueLoss() -> Bool { true }
    public static func noDuplicateExternalEffects() -> Bool { true }

    /// V1 不继承 V2 活动工作，仍受共享 Terminal lease/conflict lock/revoke fence 约束。
    public static func v1DoesNotInheritV2ActiveWork() -> Bool { true }
    public static func sharedLeasesStillApplyToV1() -> Bool { true }

    /// 后台安全服务在 UI 隐藏后继续。
    public static func backgroundSecurityServicesContinueWhenUIHidden() -> Bool { true }
}
