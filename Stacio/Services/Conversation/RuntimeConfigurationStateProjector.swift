import Foundation

// MARK: - RuntimeConfigurationStateProjector（P4-4）

/// Provider/Coding Plan `state` 关闭集合：唯一由 Projector 计算，
/// View/网络 callback 不得赋值。
public enum ProviderConfigurationState: String, Codable, CaseIterable, Equatable, Sendable {
    case savedDraft
    case needsEndpoint
    case needsCredential
    case needsVerification
    case readyToFetch
    case fetching
    case testing
    case ready
    case abandoned
}

/// Local Agent 13-state 关闭集合（固定阻断优先级由 Projector 保证）。
public enum LocalAgentConfigurationState: String, Codable, CaseIterable, Equatable, Sendable {
    case abandoned
    case processReconciliationRequired
    case detecting
    case loggingIn
    case unsupported
    case unconfigured
    case detectionFailed
    case authenticationStateUnknown
    case needsLogin
    case needsProfileSelection
    case needsVerification
    case disabled
    case ready

    /// 固定阻断优先级（值越小越阻断）：高优先级状态覆盖低优先级。
    public var blockingRank: Int {
        switch self {
        case .abandoned: return 1
        case .processReconciliationRequired: return 2
        case .detecting, .loggingIn: return 3
        case .unsupported: return 4
        case .unconfigured: return 5
        case .detectionFailed: return 6
        case .authenticationStateUnknown: return 7
        case .needsLogin: return 8
        case .needsProfileSelection: return 9
        case .needsVerification: return 10
        case .disabled: return 11
        case .ready: return 12
        }
    }
}

// MARK: - Provider 投影输入

public struct ProviderProjectionInput: Equatable, Sendable {
    public var hasSavedDraft: Bool
    public var abandoned: Bool
    public var endpointPresent: Bool
    public var credentialPresent: Bool
    /// 非 nil = 存在 ConfigurationVerificationRequest；终态决定结果。
    public var verificationState: String?
    /// 模型获取（fetching）由非终态 verificationRequest 派生，不由 Spinner 可见性写入。
    public var isFetching: Bool
    public var isTesting: Bool
    public var verificationSucceeded: Bool?

    public init(
        hasSavedDraft: Bool = false, abandoned: Bool = false,
        endpointPresent: Bool = false, credentialPresent: Bool = false,
        verificationState: String? = nil, isFetching: Bool = false,
        isTesting: Bool = false, verificationSucceeded: Bool? = nil
    ) {
        self.hasSavedDraft = hasSavedDraft
        self.abandoned = abandoned
        self.endpointPresent = endpointPresent
        self.credentialPresent = credentialPresent
        self.verificationState = verificationState
        self.isFetching = isFetching
        self.isTesting = isTesting
        self.verificationSucceeded = verificationSucceeded
    }
}

public enum RuntimeConfigurationStateProjector {

    // MARK: - Provider/Coding Plan

    /// 判定顺序（不可调换）：
    /// abandoned → savedDraft → **needsEndpoint**（nil endpoint 优先，不以 NeedsCredential 掩盖）
    /// → needsCredential → 非终态 verification（fetching/testing，由请求派生不由 Spinner 写入）
    /// → needsVerification（优先级最高且不覆盖用户值）→ readyToFetch → ready。
    public static func projectProvider(_ input: ProviderProjectionInput) -> ProviderConfigurationState {
        if input.abandoned { return .abandoned }
        guard input.hasSavedDraft else { return .savedDraft }
        guard input.endpointPresent else { return .needsEndpoint }
        guard input.credentialPresent else { return .needsCredential }
        // Fetching/Testing 由非终态 ConfigurationVerificationRequest 派生：
        // isFetching/isTesting 布尔仅作辅助，必须与非终态请求一致（Spinner 可见性不参与）。
        if let state = input.verificationState, !isTerminalVerification(state) {
            return input.isTesting ? .testing : .fetching
        }
        // 终态请求或验证结果判定
        let succeeded: Bool?
        if let state = input.verificationState {
            succeeded = state == "settledSucceeded"
        } else {
            succeeded = input.verificationSucceeded
        }
        switch succeeded {
        case .some(true):
            return input.verificationState == nil ? .readyToFetch : .ready
        default:
            return .needsVerification
        }
    }

    private static func isTerminalVerification(_ state: String) -> Bool {
        state == "settledSucceeded" || state == "settledFailed"
            || state == "settledCancelled" || state == "stateUnknown"
    }

    /// Fetching/Testing 由非终态 ConfigurationVerificationRequest 派生：
    /// 只有 verificationState 非终态才返回 true（Spinner 可见性不参与）。
    public static func isDerivedFromInFlightVerification(_ input: ProviderProjectionInput) -> Bool {
        guard let state = input.verificationState else { return false }
        return !isTerminalVerification(state)
    }

    // MARK: - Local Agent

    /// Local Agent 13 态投影：取「已满足事实」中最高阻断优先级的状态。
    public static func projectLocalAgent(
        abandoned: Bool,
        processReconciliationRequired: Bool,
        isDetecting: Bool,
        isLoggingIn: Bool,
        unsupported: Bool,
        unconfigured: Bool,
        detectionFailed: Bool,
        authenticationStateUnknown: Bool,
        needsLogin: Bool,
        needsProfileSelection: Bool,
        needsVerification: Bool,
        disabled: Bool
    ) -> LocalAgentConfigurationState {
        let candidates: [LocalAgentConfigurationState] = [
            abandoned ? .abandoned : nil,
            processReconciliationRequired ? .processReconciliationRequired : nil,
            isDetecting ? .detecting : nil,
            isLoggingIn ? .loggingIn : nil,
            unsupported ? .unsupported : nil,
            unconfigured ? .unconfigured : nil,
            detectionFailed ? .detectionFailed : nil,
            authenticationStateUnknown ? .authenticationStateUnknown : nil,
            needsLogin ? .needsLogin : nil,
            needsProfileSelection ? .needsProfileSelection : nil,
            needsVerification ? .needsVerification : nil,
            disabled ? .disabled : nil
        ].compactMap { $0 }
        let winner = candidates.min { $0.blockingRank < $1.blockingRank }
        return winner ?? .ready
    }
}

// MARK: - 字段 owner 矩阵（配置 schema 字段 ↔ Setting/Action/只读 owner 双向生成检查）

public enum ConfigurationFieldOwnerKind: Equatable, Sendable {
    case setting(String)
    case action(String)
    case readOnlyProjection
}

public struct ConfigurationFieldOwner: Equatable, Sendable {
    public let field: String
    public let owner: ConfigurationFieldOwnerKind

    public init(field: String, owner: ConfigurationFieldOwnerKind) {
        self.field = field
        self.owner = owner
    }
}

public enum ConfigurationFieldOwnerMatrix {
    public enum MatrixError: Error, Equatable {
        case zeroOwners([String])
        case multipleOwners(String, [ConfigurationFieldOwnerKind])
    }

    /// 每字段必须恰好一个 owner（无多 owner、无零 owner）；
    /// `allFields` 为配置 schema 的完整字段集（防止漏检零 owner 字段）。
    public static func validate(_ owners: [ConfigurationFieldOwner], allFields: Set<String>) throws {
        var byField: [String: [ConfigurationFieldOwnerKind]] = [:]
        for entry in owners {
            byField[entry.field, default: []].append(entry.owner)
        }
        let zeroOwners = allFields.filter { (byField[$0] ?? []).isEmpty }
        if !zeroOwners.isEmpty {
            throw MatrixError.zeroOwners(zeroOwners.sorted())
        }
        for (field, kinds) in byField where kinds.count > 1 {
            throw MatrixError.multipleOwners(field, kinds)
        }
    }
}
