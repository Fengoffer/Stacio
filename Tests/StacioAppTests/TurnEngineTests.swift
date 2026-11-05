import XCTest
import Foundation
@testable import StacioApp

/// C2-6：Turn Engine（Attempt 生命周期门禁、work-mode gate、认证校验、resume/takeover 分离）。
///
/// 合同：
/// - 一个 Turn 同时最多一个非终态 Attempt；
/// - WaitingForCapacity→StartingRuntime→Streaming 严格链（admissionGranted 后立即离开排位，
///   runtimeStarted 前不投影 Streaming、不启动有效执行时钟）；
/// - Retry/接管/崩溃恢复新 Attempt 从 Preparing 开始且不消费旧 proposal/Decision/child/nextArbitrationOrdinal；
/// - preparing 校验 `noCredentialProofDigest`（空数组/无证明不得跳过鉴权）；
/// - workMode 门禁由 Turn Engine/Policy 强制（不靠按钮）；
/// - `resumePhase` 与 `takeoverReturnPhase` 分离。
final class TurnEngineTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - helpers

    private func makeTargetBinding() -> TargetBinding {
        TargetBinding(
            id: "tb-1", revision: 1, digest: "d1", connectionID: "conn-1",
            connectionKind: "ssh", remoteIdentity: "user@host", hostKeyFingerprint: "fp",
            host: "host", user: "user", port: 22, targetWorkingDirectory: "~"
        )
    }

    private func makeAuthSnapshot(
        mode: RuntimeAuthenticationMode,
        generationIDs: [String: String] = [:],
        bindingIDs: [String] = [],
        cliScopeDigest: String? = nil,
        cliLoginDigest: String? = nil,
        noCredentialProofDigest: String? = nil,
        permitsNoCredentialEvidenceRevision: String? = nil
    ) -> RuntimeAuthenticationSnapshot {
        RuntimeAuthenticationSnapshot(
            mode: mode,
            verificationFingerprint: "vf",
            generationIDsByRole: generationIDs,
            credentialAttemptBindingIDs: bindingIDs,
            cliAuthenticationScopeDigest: cliScopeDigest,
            cliLoginIdentityDigest: cliLoginDigest,
            noCredentialProofDigest: noCredentialProofDigest,
            permitsNoCredentialEvidenceRevision: permitsNoCredentialEvidenceRevision,
            createdAt: Self.fixedDate,
            digest: "auth-digest"
        )
    }

    private func makeContextSnapshot(auth: RuntimeAuthenticationSnapshot, workMode: WorkMode = .agent) -> QueuedInputContextSnapshot {
        QueuedInputContextSnapshot(
            targetBindingSnapshot: makeTargetBinding(),
            targetWorkingDirectory: "~",
            targetDigest: "d1",
            runtimeSelectionSnapshot: AgentRuntimeSelection(kind: .nativeAPI, providerConfigurationID: "pc-1", workMode: workMode),
            runtimeAuthenticationSnapshot: auth,
            authenticationDigest: "auth-digest",
            configurationRevisionDigest: "cfg-digest",
            workMode: workMode,
            capturedAt: Self.fixedDate,
            source: .explicitUserChoice
        )
    }

    private func makeSession() -> ConversationSession {
        ConversationSession(
            id: "c-1", title: "t", createdAt: Self.fixedDate, updatedAt: Self.fixedDate,
            targetBinding: makeTargetBinding(),
            runtimeSelection: AgentRuntimeSelection(kind: .nativeAPI, providerConfigurationID: "pc-1")
        )
    }

    private func makeAttempt(
        phase: AttemptPhase,
        purpose: AttemptPurpose = .initial,
        workMode: WorkMode = .agent,
        resumePhase: AttemptPhase? = nil,
        takeoverReturnPhase: AttemptPhase? = nil,
        proposals: [ToolProposal] = [],
        decisions: [String] = [],
        nextArbitrationOrdinal: Int = 0
    ) -> TurnAttempt {
        TurnAttempt(
            id: "a-1", turnID: "t-1", ordinal: 1, phase: phase, purpose: purpose,
            runtimeSnapshot: "rs", workModeSnapshot: workMode, policySnapshot: "ps",
            toolCapabilitySnapshot: "tcs", instructionSnapshot: "is",
            toolProposalQueue: proposals, activeToolProposalID: proposals.last?.id,
            nextArbitrationOrdinal: nextArbitrationOrdinal,
            pendingDecisionIDs: decisions,
            resumePhase: resumePhase, takeoverReturnPhase: takeoverReturnPhase,
            startedAt: Self.fixedDate
        )
    }

    private func makeState(attempt: TurnAttempt? = nil) -> ConversationSessionState {
        let turn: ConversationTurn?
        if let attempt {
            turn = ConversationTurn(
                id: "t-1", sessionID: "c-1", ordinal: 1, userRequest: "hi",
                phase: attempt.phase, attempts: [attempt], activeAttemptID: attempt.id,
                timing: [:], usage: [:]
            )
        } else {
            turn = nil
        }
        return ConversationSessionState(session: makeSession(), activeTurn: turn)
    }

    private func makeIntent(
        workMode: WorkMode = .agent,
        auth: RuntimeAuthenticationSnapshot? = nil,
        requiresEffectExecution: Bool = false
    ) -> TurnSubmissionIntent {
        TurnSubmissionIntent(
            queuedInputID: "q-1",
            text: "hello",
            workMode: workMode,
            contextSnapshot: auth.map { makeContextSnapshot(auth: $0, workMode: workMode) },
            requiresEffectExecution: requiresEffectExecution
        )
    }

    // MARK: - 单非终态 Attempt

    func testOnlyOneNonTerminalAttemptPerTurn() {
        let active = makeState(attempt: makeAttempt(phase: .streaming))
        let intent = makeIntent(auth: makeAuthSnapshot(mode: .stacioCredentialBindings, generationIDs: ["api": "g-1"]))
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: active, intent: intent),
            .denied(.activeNonTerminalAttempt),
            "存在非终态 Attempt 时禁止新提交"
        )

        let terminal = makeState(attempt: makeAttempt(phase: .completed))
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: terminal, intent: intent),
            .allow,
            "终态 Attempt 后可提交新 Turn"
        )
    }

    // MARK: - 严格链

    func testAdmissionGrantedLeavesQueueAndRuntimeStartedBeforeStreaming() {
        // 走 reducer 全链，验证 admissionGranted 后立即离开排位、runtimeStarted 前不投影 Streaming
        var state = makeState()
        var seq = 1
        func apply(_ kind: ConversationEventKind) -> [EffectCommand] {
            let envelope = ConversationEventEnvelope(
                eventID: "ev-\(seq)", conversationID: "c-1", scope: .attempt,
                turnID: "t-1", attemptID: "a-1", candidateSequence: seq,
                source: "test", timestamp: Self.fixedDate, kind: kind,
                writeClass: .durable, payloadHash: "h", payload: Data()
            )
            let draft = EventDraft(envelope: envelope, expectedLastSequence: seq - 1)
            seq += 1
            let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)
            XCTAssertTrue(tentative.isValid, "\(kind) 应合法")
            state = tentative.state
            return effects
        }

        _ = apply(.turnSubmitted)
        _ = apply(.admissionRequested)
        XCTAssertEqual(state.phase, .waitingForCapacity)
        let grantedEffects = apply(.admissionGranted)
        XCTAssertEqual(state.phase, .startingRuntime, "admissionGranted 后立即离开排位")
        XCTAssertFalse(state.phase == .streaming, "runtimeStarted 前不得投影 Streaming")
        // 有效执行时钟只能在 runtimeStarted 之后启动：granted 阶段只有 startRuntime effect，无执行时钟
        XCTAssertTrue(grantedEffects.contains(.startRuntime(attemptID: "a-1")))
        _ = apply(.runtimeStarted)
        XCTAssertEqual(state.phase, .streaming, "runtimeStarted 后才进入 Streaming")
    }

    // MARK: - 新 Attempt 不消费旧状态

    func testNewAttemptFromPreparingDoesNotConsumeOldProposalDecisionChildArbitration() {
        let oldProposal = ToolProposal(
            id: "p-1", invocationID: "inv-1", batchID: "b-1", sourceChildTaskID: "ch-1",
            ordinal: 1, arbitrationOrdinal: 1, sourceToolCallID: "tc-1",
            immutableOperation: "op", operationDigest: "digest",
            state: .resolved, decisionID: "d-1", effectID: "e-1",
            terminalExecutionID: "te-1", result: "ok", error: nil
        )
        let oldAttempt = makeAttempt(
            phase: .completed, purpose: .initial, proposals: [oldProposal],
            decisions: ["d-1"], nextArbitrationOrdinal: 1
        )
        var state = makeState(attempt: oldAttempt)
        let envelope = ConversationEventEnvelope(
            eventID: "ev-retry", conversationID: "c-1", scope: .attempt,
            turnID: "t-1", attemptID: "a-2", candidateSequence: 2,
            source: "test", timestamp: Self.fixedDate, kind: .attemptStarted,
            writeClass: .durable, payloadHash: "h", payload: Data()
        )
        let (tentative, _) = ConversationReducer.reduce(
            state: state, draft: EventDraft(envelope: envelope, expectedLastSequence: 1)
        )
        XCTAssertTrue(tentative.isValid)
        state = tentative.state

        XCTAssertEqual(state.phase, .preparing, "新 Attempt 从 Preparing 开始")
        let fresh = state.activeAttempt
        XCTAssertEqual(fresh?.purpose, .retrySameConfig)
        XCTAssertTrue(fresh?.toolProposalQueue.isEmpty == true, "新 Attempt 不消费旧 proposal")
        XCTAssertTrue(fresh?.pendingDecisionIDs.isEmpty == true, "新 Attempt 不消费旧 Decision")
        XCTAssertTrue(fresh?.childTasks.isEmpty == true, "新 Attempt 不消费旧 child")
        XCTAssertEqual(fresh?.nextArbitrationOrdinal, 0, "新 Attempt 不消费旧 nextArbitrationOrdinal")
    }

    // MARK: - 认证校验

    func testPreparingRequiresNoCredentialProofDigest() {
        // noneVerified 且无免凭据证明 → 拒绝提交（空数组不得跳过鉴权）
        let bareNone = makeAuthSnapshot(mode: .noneVerified)
        let state = makeState()
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: state, intent: makeIntent(auth: bareNone)),
            .denied(.authenticationNotVerified),
            "noneVerified 无 noCredentialProofDigest 不得跳过鉴权"
        )

        // noneVerified + 有效免凭据证明 → 允许
        let provenNone = makeAuthSnapshot(
            mode: .noneVerified,
            noCredentialProofDigest: "proof",
            permitsNoCredentialEvidenceRevision: "rev-1"
        )
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: state, intent: makeIntent(auth: provenNone)),
            .allow
        )

        // stacioCredentialBindings 但 generation/binding 全空 → 拒绝（空数组不等于已验证）
        let emptyBindings = makeAuthSnapshot(mode: .stacioCredentialBindings)
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: state, intent: makeIntent(auth: emptyBindings)),
            .denied(.authenticationNotVerified)
        )

        // 有 generation → 允许
        let bound = makeAuthSnapshot(mode: .stacioCredentialBindings, generationIDs: ["api": "g-1"])
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: state, intent: makeIntent(auth: bound)),
            .allow
        )
    }

    func testPreparingRejectsIncompleteCLIEvidenceAndMixedNoneMode() {
        let state = makeState()
        let incompleteCLI = makeAuthSnapshot(
            mode: .cliManagedAuthentication,
            cliScopeDigest: "scope"
        )
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: state, intent: makeIntent(auth: incompleteCLI)),
            .denied(.authenticationNotVerified)
        )

        let mixedNone = makeAuthSnapshot(
            mode: .noneVerified,
            generationIDs: ["apiKey": "g-1"],
            noCredentialProofDigest: "proof",
            permitsNoCredentialEvidenceRevision: "rev-1"
        )
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: state, intent: makeIntent(auth: mixedNone)),
            .denied(.authenticationNotVerified)
        )
    }

    // MARK: - workMode 门禁

    func testWorkModeGateEnforcedByEngine() {
        let auth = makeAuthSnapshot(mode: .stacioCredentialBindings, generationIDs: ["api": "g-1"])
        let state = makeState()

        // answer-only 不允许 effect 执行意图（即使 UI 提供按钮也不放行）
        let answerOnlyWithEffects = makeIntent(workMode: .answerOnly, auth: auth, requiresEffectExecution: true)
        XCTAssertEqual(
            TurnEngine.gateSubmission(state: state, intent: answerOnlyWithEffects),
            .denied(.workModeDenied(required: .answerOnly))
        )
        // answer-only 纯回答 → 允许
        let answerOnlyPure = makeIntent(workMode: .answerOnly, auth: auth, requiresEffectExecution: false)
        XCTAssertEqual(TurnEngine.gateSubmission(state: state, intent: answerOnlyPure), .allow)

        // agent 模式可执行 effect
        let agentWithEffects = makeIntent(workMode: .agent, auth: auth, requiresEffectExecution: true)
        XCTAssertEqual(TurnEngine.gateSubmission(state: state, intent: agentWithEffects), .allow)
    }

    // MARK: - resume / takeover 分离

    func testResumePhaseSeparatedFromTakeoverReturnPhase() {
        let attempt = makeAttempt(
            phase: .paused,
            resumePhase: .toolProposed,
            takeoverReturnPhase: .executingTool
        )
        XCTAssertEqual(TurnEngine.resumePhase(for: attempt), .toolProposed)
        XCTAssertEqual(TurnEngine.takeoverReturnPhase(for: attempt), .executingTool)
        XCTAssertNotEqual(
            TurnEngine.resumePhase(for: attempt),
            TurnEngine.takeoverReturnPhase(for: attempt),
            "resumePhase 与 takeoverReturnPhase 必须分离"
        )

        // 缺省回退 streaming
        let plain = makeAttempt(phase: .paused)
        XCTAssertEqual(TurnEngine.resumePhase(for: plain), .streaming)
        XCTAssertEqual(TurnEngine.takeoverReturnPhase(for: plain), .streaming)
    }

    // MARK: - 接管资格

    func testTakeoverEligibilityRequiresHeldTransferredHandle() {
        // 实际持有可移交 handle（正在执行工具且带 terminal execution）才显示接管入口
        var executing = makeAttempt(phase: .executingTool, proposals: [
            ToolProposal(
                id: "p-1", invocationID: "inv-1", batchID: "b-1", sourceChildTaskID: nil,
                ordinal: 1, arbitrationOrdinal: 1, sourceToolCallID: "tc-1",
                immutableOperation: "op", operationDigest: "digest",
                state: .executing, decisionID: nil, effectID: "e-1",
                terminalExecutionID: "te-1", result: nil, error: nil
            )
        ])
        executing.terminalExecutionIDs = ["te-1"]
        let state = makeState(attempt: executing)
        XCTAssertTrue(TurnEngine.canTakeover(state: state), "持有可移交 handle 才可接管")

        let streaming = makeState(attempt: makeAttempt(phase: .streaming))
        XCTAssertFalse(TurnEngine.canTakeover(state: streaming), "streaming 无 handle 不可接管")
    }
}
