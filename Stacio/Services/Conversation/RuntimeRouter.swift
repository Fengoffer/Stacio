import Foundation

// MARK: - Runtime 认证快照校验（四种 mode 的冻结证据合同）

public enum RuntimeAuthenticationVerificationResult: Equatable, Sendable {
    case verified
    case needsVerification(reason: String)
    case credentialUnavailable
}

public enum RuntimeAuthenticationVerifier {
    /// 校验认证快照；`currentEvidenceRevision` / `expectedDescriptorRevision` 用于过期/混合 revision 判定。
    public static func validate(
        _ snapshot: RuntimeAuthenticationSnapshot,
        currentEvidenceRevision: String? = nil,
        expectedDescriptorRevision: String? = nil,
        requiredCredentialRoles: Set<String> = [],
        allowedCredentialRoles: Set<String>? = nil
    ) -> RuntimeAuthenticationVerificationResult {
        // 混合 revision：descriptor 比 evidence 新 → 需要重新验证
        if let expected = expectedDescriptorRevision, expected != snapshot.descriptorRevision {
            return .needsVerification(reason: "混合 revision：descriptor/evidence 不一致")
        }
        // 过期：当前期望 evidence revision 更新
        if let current = currentEvidenceRevision, current != snapshot.authenticationEvidenceRevision {
            return .needsVerification(reason: "authentication evidence 过期")
        }

        let normalizedGenerations = snapshot.generationIDsByRole.reduce(into: [String: String]()) {
            result, entry in
            let role = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let generationID = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard role.isEmpty == false, generationID.isEmpty == false else { return }
            result[role] = generationID
        }
        guard normalizedGenerations.count == snapshot.generationIDsByRole.count else {
            return .credentialUnavailable
        }
        if let allowedCredentialRoles,
           normalizedGenerations.keys.contains(where: { allowedCredentialRoles.contains($0) == false }) {
            return .needsVerification(reason: "credential role 与 Runtime 不匹配")
        }
        if requiredCredentialRoles.isSubset(of: Set(normalizedGenerations.keys)) == false {
            return .credentialUnavailable
        }
        let normalizedBindingIDs = snapshot.credentialAttemptBindingIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard normalizedBindingIDs.allSatisfy({ $0.isEmpty == false }),
              Set(normalizedBindingIDs).count == normalizedBindingIDs.count
        else {
            return .credentialUnavailable
        }

        switch snapshot.mode {
        case .stacioCredentialBindings:
            guard normalizedGenerations.isEmpty == false,
                  hasNoCLIEvidence(snapshot),
                  hasNoNoCredentialProof(snapshot)
            else {
                return .credentialUnavailable
            }
            return .verified
        case .cliManagedAuthentication:
            guard normalizedGenerations.isEmpty,
                  normalizedBindingIDs.isEmpty,
                  hasNoNoCredentialProof(snapshot),
                  nonEmpty(snapshot.cliAuthenticationScopeDigest),
                  nonEmpty(snapshot.cliLoginIdentityDigest)
            else {
                return .needsVerification(reason: "cliManaged 缺 CLI evidence")
            }
            return .verified
        case .combined:
            guard normalizedGenerations.isEmpty == false else {
                return .credentialUnavailable
            }
            guard nonEmpty(snapshot.cliAuthenticationScopeDigest),
                  nonEmpty(snapshot.cliLoginIdentityDigest),
                  hasNoNoCredentialProof(snapshot)
            else {
                return .needsVerification(reason: "combined 缺 CLI evidence")
            }
            return .verified
        case .noneVerified:
            guard normalizedGenerations.isEmpty,
                  normalizedBindingIDs.isEmpty,
                  hasNoCLIEvidence(snapshot),
                  nonEmpty(snapshot.noCredentialProofDigest),
                  nonEmpty(snapshot.permitsNoCredentialEvidenceRevision)
            else {
                return .needsVerification(reason: "noneVerified 缺免凭据证明")
            }
            return .verified
        }
    }

    private static func hasNoCLIEvidence(_ snapshot: RuntimeAuthenticationSnapshot) -> Bool {
        nonEmpty(snapshot.cliAuthenticationScopeDigest) == false
            && nonEmpty(snapshot.cliLoginIdentityDigest) == false
    }

    private static func hasNoNoCredentialProof(_ snapshot: RuntimeAuthenticationSnapshot) -> Bool {
        nonEmpty(snapshot.noCredentialProofDigest) == false
            && nonEmpty(snapshot.permitsNoCredentialEvidenceRevision) == false
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

// MARK: - RuntimeRouter（显式绑定，无自动换路）

public enum RuntimeRouterDecision: Equatable, Sendable {
    case native(providerConfigurationID: String)
    case codingPlan(codingPlanConfigurationID: String)
    case localAgent(localAgentConfigurationID: String)
}

public enum RuntimeRouterError: Equatable, Sendable, Error {
    /// 会话没有明确的 Runtime 选择
    case selectionUnresolved
    /// 选择同时包含多个互斥的 Runtime 身份
    case selectionAmbiguous
    /// 选择的身份类型与 Runtime kind 不匹配
    case selectionKindMismatch
    /// 显式选择的 Runtime 不可用（失败不自动换路）
    case selectedRuntimeUnavailable(reason: String)
    case authenticationNeedsVerification
    case credentialUnavailable
}

public enum RuntimeRouter {
    /// 按会话显式绑定选择 Native/Local Agent；任一失败返回 error，绝不自动换路。
    public static func route(
        session: ConversationSession,
        authentication: RuntimeAuthenticationSnapshot?
    ) -> Result<RuntimeRouterDecision, RuntimeRouterError> {
        switch session.runtimeSelection.kind {
        case .nativeAPI:
            // Native API 选择必须恰好绑定一个配置；不要把 coding plan
            // 静默降级成普通 provider，也不要在两个 ID 同时存在时猜测。
            guard session.runtimeSelection.localAgentConfigurationID == nil,
                  session.runtimeSelection.localAgentExecutionProfileID == nil,
                  session.runtimeSelection.localAgentExecutionProfileKind == .none
            else {
                return .failure(.selectionKindMismatch)
            }
            let providerID = session.runtimeSelection.providerConfigurationID
            let codingPlanID = session.runtimeSelection.codingPlanConfigurationID
            guard (providerID == nil) != (codingPlanID == nil) else {
                return providerID == nil ? .failure(.selectionUnresolved) : .failure(.selectionAmbiguous)
            }
            guard let selectedConfigurationID = providerID ?? codingPlanID,
                  selectedConfigurationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return .failure(.selectionUnresolved)
            }
            guard let authentication else {
                return .failure(.authenticationNeedsVerification)
            }
            guard authentication.configurationID == selectedConfigurationID else {
                return .failure(.authenticationNeedsVerification)
            }
            let requiredRoles: Set<String> = authentication.mode == .noneVerified
                ? []
                : ["apiKey"]
            switch RuntimeAuthenticationVerifier.validate(
                authentication,
                requiredCredentialRoles: requiredRoles,
                allowedCredentialRoles: ["apiKey"]
            ) {
            case .verified:
                if let providerID {
                    return .success(.native(providerConfigurationID: providerID))
                }
                return .success(.codingPlan(codingPlanConfigurationID: selectedConfigurationID))
            case .needsVerification:
                return .failure(.authenticationNeedsVerification)
            case .credentialUnavailable:
                return .failure(.credentialUnavailable)
            }
        case .localAgent:
            guard let localID = session.runtimeSelection.localAgentConfigurationID,
                  localID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            else {
                return .failure(.selectionUnresolved)
            }
            guard let profileID = session.runtimeSelection.localAgentExecutionProfileID,
                  profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  session.runtimeSelection.localAgentExecutionProfileKind != .none
            else {
                return .failure(.selectionUnresolved)
            }
            guard session.runtimeSelection.providerConfigurationID == nil,
                  session.runtimeSelection.codingPlanConfigurationID == nil,
                  session.runtimeSelection.modelID == nil
            else {
                return .failure(.selectionKindMismatch)
            }
            guard let authentication else {
                return .failure(.authenticationNeedsVerification)
            }
            guard authentication.configurationID == localID else {
                return .failure(.authenticationNeedsVerification)
            }
            switch RuntimeAuthenticationVerifier.validate(authentication) {
            case .verified:
                break
            case .needsVerification:
                return .failure(.authenticationNeedsVerification)
            case .credentialUnavailable:
                return .failure(.credentialUnavailable)
            }
            return .success(.localAgent(localAgentConfigurationID: localID))
        }
    }
}
