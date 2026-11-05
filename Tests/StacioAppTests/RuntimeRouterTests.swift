import XCTest
import Foundation
@testable import StacioApp

/// C2-7：RuntimeCapabilities、RuntimeRouter 与四种认证模式。
///
/// 合同：
/// - 能力来自协议握手/工具目录/配置而非显示名称；`availableToolIDs` 冻结到 Attempt snapshot；
/// - 未声明工具拒绝；managedExecution/launchCapabilityBinding/workModeEnforcement 不能由用户手动提升；
/// - 纯 PTY 永远无 workModeEnforcement/answerOnlyRuntimeLaunch；
/// - RuntimeAuthenticationSnapshot 四 mode 各自冻结 generation/binding/CLI evidence/noneVerified proof；
/// - mode 过期/混合 revision → NeedsVerification；缺凭据 → credentialUnavailable；
/// - Router 按会话显式绑定选择 Native/Local，失败后不自动换路。
final class RuntimeRouterTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - 能力来源

    func testCapabilitiesDerivedFromHandshakeNotDisplayName() {
        let base = RuntimeCapabilities(streaming: true, toolCalling: false)
        // 显示名再像 agent 也不贡献能力
        let resolved = RuntimeCapabilityResolver.resolve(capabilities: base, displayName: "SuperToolAgent X")
        XCTAssertEqual(resolved.streaming, true)
        XCTAssertEqual(resolved.toolCalling, false, "显示名不得提升未声明能力")
        XCTAssertEqual(resolved, base, "resolve 只保留已声明能力")
    }

    func testAvailableToolIDsFrozenToSnapshot() {
        let caps = RuntimeCapabilities(toolCalling: true, availableToolIDs: ["bash", "read"], toolCatalogRevision: "rev-3")
        let digest1 = RuntimeCapabilityResolver.snapshotDigest(for: caps)
        let digest2 = RuntimeCapabilityResolver.snapshotDigest(for: caps)
        XCTAssertEqual(digest1, digest2, "同一 Attempt 内能力快照必须冻结（确定性 digest）")

        let changed = RuntimeCapabilities(toolCalling: true, availableToolIDs: ["bash"], toolCatalogRevision: "rev-3")
        XCTAssertNotEqual(digest1, RuntimeCapabilityResolver.snapshotDigest(for: changed), "能力变化必须改变 digest")
    }

    func testUndeclaredToolRejected() {
        let caps = RuntimeCapabilities(toolCalling: true, availableToolIDs: ["bash", "read"])
        XCTAssertTrue(RuntimeCapabilityResolver.declaresTool("bash", in: caps))
        XCTAssertFalse(RuntimeCapabilityResolver.declaresTool("unlisted-tool", in: caps), "未声明工具必须拒绝")
    }

    func testUserCannotManuallyElevateManagedCapabilities() {
        let caps = RuntimeCapabilities(streaming: true, managedExecution: false, workModeEnforcement: false)
        var request = RuntimeUserElevationRequest()
        request.managedExecution = true
        request.workModeEnforcement = true
        XCTAssertTrue(
            RuntimeCapabilityResolver.userElevationBlocked(capabilities: caps, requested: request),
            "用户不得手动提升未声明能力"
        )
        // 已声明能力重复请求不是提升
        let declared = RuntimeCapabilities(streaming: true, managedExecution: true, workModeEnforcement: true)
        XCTAssertFalse(
            RuntimeCapabilityResolver.userElevationBlocked(capabilities: declared, requested: request),
            "已声明能力的请求不算提升"
        )
    }

    func testPurePTYNeverHasWorkModeEnforcementOrAnswerOnlyLaunch() {
        let pty = RuntimeCapabilityResolver.ptyCapabilities()
        XCTAssertFalse(pty.workModeEnforcement, "纯 PTY 永远无 workModeEnforcement")
        XCTAssertFalse(pty.answerOnlyRuntimeLaunch, "纯 PTY 永远无 answerOnlyRuntimeLaunch")
        XCTAssertFalse(pty.managedExecution)
        XCTAssertEqual(pty.allowedWorkModes, [])
    }

    // MARK: - 四认证模式

    private func auth(
        mode: RuntimeAuthenticationMode,
        configurationID: String? = nil,
        generationIDs: [String: String] = [:],
        bindingIDs: [String] = [],
        cliScopeDigest: String? = nil,
        cliLoginDigest: String? = nil,
        noCredentialProof: String? = nil,
        permitsRevision: String? = nil,
        evidenceRevision: String? = "rev-1"
    ) -> RuntimeAuthenticationSnapshot {
        RuntimeAuthenticationSnapshot(
            mode: mode,
            configurationID: configurationID,
            catalogSetRevision: "catalog-1",
            descriptorRevision: "descriptor-1",
            verificationFingerprint: "vf",
            generationIDsByRole: generationIDs,
            credentialAttemptBindingIDs: bindingIDs,
            cliAuthenticationScopeDigest: cliScopeDigest,
            cliLoginIdentityDigest: cliLoginDigest,
            authenticationEvidenceRevision: evidenceRevision,
            noCredentialProofDigest: noCredentialProof,
            permitsNoCredentialEvidenceRevision: permitsRevision,
            createdAt: Self.fixedDate,
            digest: "auth-digest"
        )
    }

    func testStacioCredentialBindingsModeFreezesGenerationAndBinding() {
        // 空 generation/binding → credentialUnavailable（不等于已验证）
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(auth(mode: .stacioCredentialBindings)),
            .credentialUnavailable
        )
        // 有 generation → verified
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(auth(mode: .stacioCredentialBindings, generationIDs: ["apiKey": "g-1"])),
            .verified
        )
        // binding 不能代替 generation identity
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(auth(mode: .stacioCredentialBindings, bindingIDs: ["b-1"])),
            .credentialUnavailable
        )
    }

    func testCliManagedModeRequiresScopeAndLoginEvidence() {
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(auth(mode: .cliManagedAuthentication)),
            .needsVerification(reason: "cliManaged 缺 CLI evidence")
        )
        let full = auth(
            mode: .cliManagedAuthentication,
            cliScopeDigest: "scope",
            cliLoginDigest: "login"
        )
        XCTAssertEqual(RuntimeAuthenticationVerifier.validate(full), .verified)
    }

    func testCombinedModeRequiresBothEvidence() {
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(auth(mode: .combined, generationIDs: ["api": "g-1"])),
            .needsVerification(reason: "combined 缺 CLI evidence")
        )
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(
                auth(mode: .combined, generationIDs: ["api": "g-1"], cliScopeDigest: "scope")
            ),
            .needsVerification(reason: "combined 缺 CLI evidence")
        )
        let full = auth(
            mode: .combined,
            generationIDs: ["api": "g-1"],
            cliScopeDigest: "scope",
            cliLoginDigest: "login"
        )
        XCTAssertEqual(RuntimeAuthenticationVerifier.validate(full), .verified)
    }

    func testNoneVerifiedModeRequiresPermittedProofDigest() {
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(auth(mode: .noneVerified)),
            .needsVerification(reason: "noneVerified 缺免凭据证明")
        )
        let proven = auth(
            mode: .noneVerified,
            noCredentialProof: "proof",
            permitsRevision: "permit-rev"
        )
        XCTAssertEqual(RuntimeAuthenticationVerifier.validate(proven), .verified)
    }

    func testAuthenticationEvidenceRejectsBlankValues() {
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(
                auth(mode: .stacioCredentialBindings, generationIDs: ["api": "  "])
            ),
            .credentialUnavailable
        )
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(
                auth(mode: .cliManagedAuthentication, cliScopeDigest: "scope", cliLoginDigest: " ")
            ),
            .needsVerification(reason: "cliManaged 缺 CLI evidence")
        )
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(
                auth(mode: .noneVerified, noCredentialProof: "", permitsRevision: "permit-rev")
            ),
            .needsVerification(reason: "noneVerified 缺免凭据证明")
        )
    }

    func testAuthenticationEvidenceRejectsModeMixingAndWrongNativeRole() {
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(
                auth(
                    mode: .cliManagedAuthentication,
                    generationIDs: ["apiKey": "g-1"],
                    cliScopeDigest: "scope",
                    cliLoginDigest: "login"
                )
            ),
            .needsVerification(reason: "cliManaged 缺 CLI evidence")
        )
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(
                auth(mode: .noneVerified, bindingIDs: ["b-1"], noCredentialProof: "proof", permitsRevision: "rev")
            ),
            .needsVerification(reason: "noneVerified 缺免凭据证明")
        )
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(
                auth(mode: .stacioCredentialBindings, generationIDs: ["proxy": "g-1"]),
                requiredCredentialRoles: ["apiKey"],
                allowedCredentialRoles: ["apiKey"]
            ),
            .needsVerification(reason: "credential role 与 Runtime 不匹配")
        )
    }

    func testExpiredOrMixedRevisionNeedsVerification() {
        let bound = auth(mode: .stacioCredentialBindings, generationIDs: ["api": "g-1"], evidenceRevision: "rev-3")
        // 当前期望证据 revision 更新 → 过期
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(bound, currentEvidenceRevision: "rev-4"),
            .needsVerification(reason: "authentication evidence 过期")
        )
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(bound, currentEvidenceRevision: "rev-3"),
            .verified
        )
        // 混合 revision：descriptor 比 evidence 新 → 混合
        let mixed = auth(
            mode: .stacioCredentialBindings,
            generationIDs: ["api": "g-1"],
            evidenceRevision: "rev-2"
        )
        XCTAssertEqual(
            RuntimeAuthenticationVerifier.validate(mixed, currentEvidenceRevision: "rev-2", expectedDescriptorRevision: "descriptor-2"),
            .needsVerification(reason: "混合 revision：descriptor/evidence 不一致")
        )
    }

    // MARK: - Router 显式绑定

    private func makeSession(
        kind: AgentRuntimeSelectionKind,
        providerID: String? = nil,
        codingPlanID: String? = nil,
        localID: String? = nil
    ) -> ConversationSession {
        ConversationSession(
            id: "c-1", title: "t", createdAt: Self.fixedDate, updatedAt: Self.fixedDate,
            targetBinding: TargetBinding(
                id: "tb-1", revision: 1, digest: "d", connectionID: "conn",
                connectionKind: "ssh", remoteIdentity: "u@h", hostKeyFingerprint: "fp",
                host: "h", user: "u", port: 22, targetWorkingDirectory: "~"
            ),
            runtimeSelection: AgentRuntimeSelection(
                kind: kind, providerConfigurationID: providerID,
                codingPlanConfigurationID: codingPlanID,
                localAgentConfigurationID: localID,
                localAgentExecutionProfileID: localID == nil ? nil : "profile-1",
                localAgentExecutionProfileKind: localID == nil ? .none : .managed
            )
        )
    }

    func testRouterSelectsExplicitNativeBinding() {
        let session = makeSession(kind: .nativeAPI, providerID: "pc-1")
        let authSnap = auth(
            mode: .stacioCredentialBindings,
            configurationID: "pc-1",
            generationIDs: ["apiKey": "g-1"]
        )
        let decision = RuntimeRouter.route(session: session, authentication: authSnap)
        XCTAssertEqual(decision, .success(.native(providerConfigurationID: "pc-1")))
    }

    func testRouterSelectsExplicitLocalAgentBinding() {
        let session = makeSession(kind: .localAgent, localID: "lc-1")
        let authSnap = auth(
            mode: .cliManagedAuthentication,
            configurationID: "lc-1",
            cliScopeDigest: "scope",
            cliLoginDigest: "login"
        )
        XCTAssertEqual(
            RuntimeRouter.route(session: session, authentication: authSnap),
            .success(.localAgent(localAgentConfigurationID: "lc-1"))
        )
        XCTAssertEqual(
            RuntimeRouter.route(session: session, authentication: nil),
            .failure(.authenticationNeedsVerification)
        )
    }

    func testRouterSelectsExplicitCodingPlanBinding() {
        let session = makeSession(kind: .nativeAPI, codingPlanID: "cp-1")
        let authSnap = auth(
            mode: .stacioCredentialBindings,
            configurationID: "cp-1",
            generationIDs: ["apiKey": "g-1"]
        )
        XCTAssertEqual(
            RuntimeRouter.route(session: session, authentication: authSnap),
            .success(.codingPlan(codingPlanConfigurationID: "cp-1"))
        )
    }

    func testRouterFailsWithoutFailoverOnCredentialUnavailable() {
        // 显式 native 绑定但凭据缺失 → 失败；绝不自动换路到 Local Agent
        let session = makeSession(kind: .nativeAPI, providerID: "pc-1")
        let emptyAuth = auth(mode: .stacioCredentialBindings, configurationID: "pc-1")
        XCTAssertEqual(
            RuntimeRouter.route(session: session, authentication: emptyAuth),
            .failure(.credentialUnavailable),
            "显式绑定失败必须失败，不能自动换路"
        )
        let noAuth = RuntimeRouter.route(session: session, authentication: nil)
        guard case .failure(let error) = noAuth else {
            return XCTFail("无认证快照必须失败")
        }
        XCTAssertNotEqual(error, .credentialUnavailable)
    }

    func testRouterSelectionUnresolved() {
        let session = makeSession(kind: .nativeAPI, providerID: nil)
        XCTAssertEqual(
            RuntimeRouter.route(session: session, authentication: nil),
            .failure(.selectionUnresolved)
        )
    }

    func testRouterRejectsAmbiguousNativeSelection() {
        let session = makeSession(kind: .nativeAPI, providerID: "pc-1", codingPlanID: "cp-1")
        let authSnap = auth(
            mode: .stacioCredentialBindings,
            configurationID: "pc-1",
            generationIDs: ["apiKey": "g-1"]
        )
        XCTAssertEqual(
            RuntimeRouter.route(session: session, authentication: authSnap),
            .failure(.selectionAmbiguous)
        )
    }

    func testRouterRejectsWrongKindIdentity() {
        let nativeWithLocal = makeSession(kind: .nativeAPI, providerID: "pc-1", localID: "lc-1")
        XCTAssertEqual(
            RuntimeRouter.route(session: nativeWithLocal, authentication: nil),
            .failure(.selectionKindMismatch)
        )

        let localWithProvider = makeSession(kind: .localAgent, providerID: "pc-1", localID: "lc-1")
        XCTAssertEqual(
            RuntimeRouter.route(session: localWithProvider, authentication: nil),
            .failure(.selectionKindMismatch)
        )
    }

    func testRouterRejectsHiddenLocalAgentProfileOnNativeSelection() {
        var session = makeSession(kind: .nativeAPI, providerID: "pc-1")
        session.runtimeSelection.localAgentExecutionProfileID = "profile-1"
        session.runtimeSelection.localAgentExecutionProfileKind = .managed
        let authSnap = auth(
            mode: .stacioCredentialBindings,
            configurationID: "pc-1",
            generationIDs: ["apiKey": "g-1"]
        )
        XCTAssertEqual(
            RuntimeRouter.route(session: session, authentication: authSnap),
            .failure(.selectionKindMismatch)
        )
    }

    func testRouterRequiresProfileForLocalAgentSelection() {
        let session = makeSession(kind: .localAgent, localID: "lc-1")
        var missingProfile = session
        missingProfile.runtimeSelection.localAgentExecutionProfileID = nil
        XCTAssertEqual(
            RuntimeRouter.route(session: missingProfile, authentication: nil),
            .failure(.selectionUnresolved)
        )
    }

    func testRouterRejectsBlankAndMismatchedConfigurationIdentity() {
        let blank = makeSession(kind: .nativeAPI, providerID: "  ")
        XCTAssertEqual(
            RuntimeRouter.route(session: blank, authentication: nil),
            .failure(.selectionUnresolved)
        )

        let selected = makeSession(kind: .nativeAPI, providerID: "pc-1")
        let wrongAuthentication = auth(
            mode: .stacioCredentialBindings,
            configurationID: "pc-2",
            generationIDs: ["apiKey": "g-1"]
        )
        XCTAssertEqual(
            RuntimeRouter.route(session: selected, authentication: wrongAuthentication),
            .failure(.authenticationNeedsVerification)
        )
    }
}
