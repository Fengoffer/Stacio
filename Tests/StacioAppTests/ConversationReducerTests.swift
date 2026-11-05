import XCTest
import Foundation
@testable import StacioApp

/// C2-3：纯 ConversationReducer 与 Attempt phase transition table。
///
/// 合同：
/// - 签名 `(ConversationSessionState, EventDraft) -> (TentativeState, [EffectCommand])`，纯函数；
/// - 全状态转换覆盖 §11 Attempt 状态机（含 WaitingForCapacity/StartingRuntime 扩展）；
/// - 非法边被 phase transition table 拒绝；
/// - `workModeDenied` 只结算 proposal/decision，不伪造 Attempt 终态 reasonCode；
/// - `approvalExpired`（decisionExpired）不是 Attempt terminal reason；
/// - answer-only 模式下 Tool/Approval/Execution/SecureInput/ChildTask/Pause/Takeover 不可达，
///   且不产生任何带 authority 的 effect。
final class ConversationReducerTests: XCTestCase {

    // MARK: - 测试构造 helper

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTargetBinding() -> TargetBinding {
        TargetBinding(
            id: "tb-1", revision: 1, digest: "d1", connectionID: "conn-1",
            connectionKind: "ssh", remoteIdentity: "user@host", hostKeyFingerprint: "fp",
            host: "host", user: "user", port: 22, targetWorkingDirectory: "~"
        )
    }

    private func makeRuntimeSelection(workMode: WorkMode = .agent) -> AgentRuntimeSelection {
        AgentRuntimeSelection(kind: .nativeAPI, providerConfigurationID: "pc-1", workMode: workMode)
    }

    private func makeSession(workMode: WorkMode = .agent) -> ConversationSession {
        ConversationSession(
            id: "c-1", title: "t", createdAt: Self.fixedDate, updatedAt: Self.fixedDate,
            targetBinding: makeTargetBinding(), runtimeSelection: makeRuntimeSelection(workMode: workMode)
        )
    }

    private func makeAttempt(
        id: String = "a-1",
        phase: AttemptPhase = .preparing,
        purpose: AttemptPurpose = .initial,
        workMode: WorkMode = .agent,
        turnID: String = "t-1",
        startedAt: Date = ConversationReducerTests.fixedDate
    ) -> TurnAttempt {
        TurnAttempt(
            id: id, turnID: turnID, ordinal: 1, phase: phase, purpose: purpose,
            runtimeSnapshot: "rs", workModeSnapshot: workMode, policySnapshot: "ps",
            toolCapabilitySnapshot: "tcs", instructionSnapshot: "is",
            startedAt: startedAt
        )
    }

    private func makeAutomaticApprovalState() -> (
        state: ConversationSessionState,
        evidence: ApprovalNotRequiredPayload
    ) {
        let automationPolicy = SessionAutomationPolicy(
            environment: "development",
            aiExecutionPolicy: "readOnlyAuto"
        )
        let snapshot = AgentToolAuthorizationPolicySnapshot(
            globalPolicy: .allowReadOnlyExternalCommands,
            commandPolicy: AgentCommandPatternPolicy(),
            automationPolicy: automationPolicy,
            targetRuntimeID: "conn-1",
            targetRuntimeGeneration: 7,
            targetBindingDigest: "d1",
            capturedAt: Self.fixedDate
        )
        var attempt = makeAttempt(phase: .streaming)
        attempt.targetBindingSnapshot = makeTargetBinding()
        attempt.targetRuntimeGeneration = 7
        attempt.toolAuthorizationPolicySnapshot = snapshot
        var state = makeState(attempt: attempt)
        _ = applyEvent(
            state: &state,
            kind: .toolProposed,
            payload: makeToolProposalBatchPayload()
        )
        let proposal = state.activeAttempt!.toolProposalQueue[0]
        let evidence = ApprovalNotRequiredPayload(
            proposalID: proposal.id,
            requestDigest: proposal.operationDigest,
            policySnapshotDigest: snapshot.digest,
            targetBindingDigest: "d1",
            targetRuntimeGeneration: 7,
            reason: "allowed by session policy",
            risk: "readOnly",
            createdAt: Self.fixedDate
        )
        return (state, evidence)
    }

    private func makeToolProposalBatchPayload(
        proposalID: String = "proposal-1",
        command: String = "uptime"
    ) -> Data {
        let proposal = ConversationToolProposalPayload(
            proposalID: proposalID,
            invocationID: "invocation-1",
            batchID: "batch-1",
            ordinal: 1,
            command: command,
            explanation: "读取系统状态",
            risk: "readOnly",
            targetRuntimeID: "conn-1",
            targetTitle: "user@host"
        )
        return encoded(ConversationToolProposalBatchPayload(proposals: [proposal]))
    }

    private func applyToolProposalAwaitingApproval(
        state: inout ConversationSessionState
    ) {
        _ = applyEvent(
            state: &state,
            kind: .toolProposed,
            payload: makeToolProposalBatchPayload()
        )
        let proposal = state.activeAttempt!.toolProposalQueue[0]
        let request = ApprovalRequestedPayload(
            decisionID: "d-1",
            proposalID: proposal.id,
            requestDigest: proposal.operationDigest,
            createdAt: Self.fixedDate,
            deadline: Self.fixedDate.addingTimeInterval(60)
        )
        _ = applyEvent(
            state: &state,
            kind: .approvalRequested,
            payload: encoded(request)
        )
    }

    private func makeTurn(attempt: TurnAttempt) -> ConversationTurn {
        ConversationTurn(
            id: attempt.turnID, sessionID: "c-1", ordinal: 1, userRequest: "hello",
            phase: attempt.phase, attempts: [attempt], activeAttemptID: attempt.id,
            timing: [:], usage: [:]
        )
    }

    private func makeState(
        session: ConversationSession? = nil,
        attempt: TurnAttempt? = nil,
        decisions: [String: Decision] = [:],
        lastApplied: Int = 0
    ) -> ConversationSessionState {
        let s = session ?? makeSession()
        let turn: ConversationTurn?
        if let attempt {
            turn = makeTurn(attempt: attempt)
        } else {
            turn = nil
        }
        return ConversationSessionState(
            session: s, activeTurn: turn, decisions: decisions, lastAppliedSequence: lastApplied
        )
    }

    private func makeDraft(
        kind: ConversationEventKind,
        sequence: Int = 1,
        expectedLast: Int = 0,
        scope: ConversationEventScope = .attempt,
        turnID: String? = "t-1",
        attemptID: String? = "a-1",
        payload: Data = Data(),
        eventID: String = "ev-1"
    ) -> EventDraft {
        let envelope = ConversationEventEnvelope(
            eventID: eventID, conversationID: "c-1", scope: scope,
            turnID: turnID, attemptID: attemptID, candidateSequence: sequence,
            source: "test", timestamp: ConversationReducerTests.fixedDate,
            kind: kind, writeClass: .durable, payloadHash: "h", payload: payload
        )
        return EventDraft(envelope: envelope, expectedLastSequence: expectedLast)
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        try! JSONEncoder().encode(value)
    }

    // MARK: - 纯函数与签名

    func testReducerSignatureIsPureStateTransition() {
        // 编译期验证签名：reducer 返回 (TentativeState, [EffectCommand])，不执行副作用
        let state = makeState()
        let draft = makeDraft(kind: .sessionCreated)
        let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertEqual(tentative.state.lastAppliedSequence, 1)
        XCTAssertTrue(effects.isEmpty, "sessionCreated 不产生 effect")
    }

    func testReducerIsDeterministicPureFunction() {
        // 相同输入两次调用产出逐字节相同结果（无时钟/随机/外部状态）
        let state = makeState()
        let draft = makeDraft(kind: .turnSubmitted, sequence: 1)
        let (firstTentative, firstEffects) = ConversationReducer.reduce(state: state, draft: draft)
        let (secondTentative, secondEffects) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertEqual(firstTentative, secondTentative)
        XCTAssertEqual(firstEffects, secondEffects)
    }

    func testReducerRejectsSequenceGap() {
        // expectedLastSequence 与候选序号不连续时，reducer 必须拒绝应用（Actor/持久层负责 buffering，
        // reducer 不投影乱序事件）
        let state = makeState(lastApplied: 5)
        let draft = makeDraft(kind: .turnSubmitted, sequence: 7, expectedLast: 5)
        let (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertFalse(tentative.isValid, "序列缺口必须被拒绝")
        XCTAssertEqual(tentative.state.lastAppliedSequence, 5, "缺口事件不得推进 lastAppliedSequence")
    }

    func testStructuredTurnRejectsAmbiguousRuntimeSnapshot() {
        let state = makeState()
        let ambiguous = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: "provider-1",
            codingPlanConfigurationID: "plan-1"
        )
        let submitted = TurnSubmittedPayload(
            text: "inspect runtime",
            runtimeSelection: ambiguous,
            targetBinding: makeTargetBinding()
        )
        let draft = makeDraft(
            kind: .turnSubmitted,
            payload: encoded(submitted)
        )

        let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)

        XCTAssertFalse(tentative.isValid)
        XCTAssertNil(tentative.state.activeTurn)
        XCTAssertEqual(tentative.state.lastAppliedSequence, 0)
        XCTAssertTrue(effects.isEmpty)
    }

    func testNextTurnOrdinalMustIncreaseAndLegacyPayloadIsMigratedMonotonically() {
        let completed = makeAttempt(phase: .completed)
        let state = makeState(attempt: completed, lastApplied: 1)
        let stale = TurnSubmittedPayload(
            text: "next",
            runtimeSelection: makeRuntimeSelection(),
            targetBinding: makeTargetBinding(),
            ordinal: 1
        )
        let staleDraft = makeDraft(
            kind: .turnSubmitted,
            sequence: 2,
            expectedLast: 1,
            turnID: "t-2",
            attemptID: "a-2",
            payload: encoded(stale)
        )

        let rejected = ConversationReducer.reduce(state: state, draft: staleDraft).0
        XCTAssertFalse(rejected.isValid)
        XCTAssertEqual(rejected.state.activeTurn?.id, "t-1")

        let legacyDraft = makeDraft(
            kind: .turnSubmitted,
            sequence: 2,
            expectedLast: 1,
            turnID: "t-2",
            attemptID: "a-2",
            payload: Data("legacy next".utf8)
        )
        let migrated = ConversationReducer.reduce(state: state, draft: legacyDraft).0
        XCTAssertTrue(migrated.isValid)
        XCTAssertEqual(migrated.state.activeTurn?.ordinal, 2)
    }

    // MARK: - §11 全状态转换链

    func testHappyPathFullTransitionChain() {
        // sessionCreated → turnSubmitted → admissionRequested → admissionGranted → runtimeStarted
        // → streaming → toolProposed → user approval → executingTool → toolProposalResolved
        // → streaming → attemptCompleted(completed)
        var state = makeState()
        var seq = 1

        func apply(_ kind: ConversationEventKind, payload: Data = Data(), file: StaticString = #filePath, line: UInt = #line) -> [EffectCommand] {
            let draft = makeDraft(kind: kind, sequence: seq, expectedLast: seq - 1, payload: payload)
            seq += 1
            let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)
            XCTAssertTrue(tentative.isValid, "\(kind) 应合法", file: file, line: line)
            state = tentative.state
            return effects
        }

        _ = apply(.sessionCreated)
        let turnEffects = apply(.turnSubmitted)
        XCTAssertEqual(turnEffects, [.requestAdmission(sessionID: "c-1", turnID: "t-1", attemptID: "a-1")])
        _ = apply(.admissionRequested)
        XCTAssertEqual(state.phase, .waitingForCapacity)
        let startEffects = apply(.admissionGranted)
        XCTAssertEqual(startEffects, [.startRuntime(attemptID: "a-1")])
        XCTAssertEqual(state.phase, .startingRuntime)
        _ = apply(.runtimeStarted)
        XCTAssertEqual(state.phase, .streaming)
        let invocationStarted = ModelInvocationStartedPayload(
            invocationID: "model-a-1-1",
            ordinal: 1,
            contextSnapshotID: "context-model-a-1-1",
            contextDigest: "sha256:test",
            runtimeCapabilitySnapshot: "test-runtime",
            startedAt: Date(timeIntervalSince1970: 1)
        )
        _ = apply(.modelInvocationStarted, payload: encoded(invocationStarted))
        XCTAssertEqual(state.phase, .streaming)
        let invocationCompleted = ModelInvocationCompletedPayload(
            invocationID: "model-a-1-1",
            endedAt: Date(timeIntervalSince1970: 2),
            outcome: "completed"
        )
        _ = apply(.modelInvocationCompleted, payload: encoded(invocationCompleted))
        _ = apply(.toolProposed, payload: makeToolProposalBatchPayload())
        XCTAssertEqual(state.phase, .toolProposed)
        let proposal = state.activeAttempt!.toolProposalQueue[0]
        let request = ApprovalRequestedPayload(
            decisionID: "d-1",
            proposalID: proposal.id,
            requestDigest: proposal.operationDigest,
            createdAt: Self.fixedDate,
            deadline: Self.fixedDate.addingTimeInterval(60)
        )
        _ = apply(.approvalRequested, payload: encoded(request))
        let approval = ApprovalResolutionPayload(
            decisionID: "d-1",
            approved: true,
            resolutionSource: "user"
        )
        _ = apply(.approvalResolved, payload: encoded(approval))
        XCTAssertEqual(state.phase, .executingTool)
        _ = apply(.toolProposalResolved)
        XCTAssertEqual(state.phase, .streaming)
        let completed = AttemptTerminationPayload(outcome: .completed, reasonCode: .completed)
        _ = apply(.attemptCompleted, payload: encoded(completed))
        XCTAssertEqual(state.phase, .completed)
        XCTAssertTrue(state.activeAttempt?.outcome == .completed)
        XCTAssertTrue(PhaseTransitionTable.isTerminal(state.phase))
    }

    func testApprovalPathResolvesDecision() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        applyToolProposalAwaitingApproval(state: &state)
        XCTAssertEqual(state.phase, .awaitingApproval)
        let resolution = ApprovalResolutionPayload(decisionID: "d-1", approved: true, resolutionSource: "user")
        _ = applyEvent(state: &state, kind: .approvalResolved, payload: encoded(resolution))
        XCTAssertEqual(state.phase, .executingTool)
        XCTAssertEqual(state.decisions["d-1"]?.state, .approved)
        XCTAssertEqual(state.activeAttempt?.toolProposalQueue.first?.approvalSource, .userApproved)
    }

    func testAutomaticApprovalPersistsAuthorityOnProposalProjection() {
        var (state, evidence) = makeAutomaticApprovalState()

        let effects = applyEvent(
            state: &state,
            kind: .approvalNotRequired,
            payload: encoded(evidence)
        )

        XCTAssertEqual(state.phase, .executingTool)
        XCTAssertEqual(state.activeAttempt?.toolProposalQueue.first?.approvalSource, .policyAutoAllowed)
        XCTAssertTrue(effects.contains(.executeTool(attemptID: "a-1", proposalID: evidence.proposalID)))
    }

    func testApprovalNotRequiredRejectsMissingDurableEvidence() {
        let (state, _) = makeAutomaticApprovalState()
        let draft = makeDraft(
            kind: .approvalNotRequired,
            sequence: state.lastAppliedSequence + 1,
            expectedLast: state.lastAppliedSequence,
            payload: Data()
        )

        let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)

        XCTAssertFalse(tentative.isValid)
        XCTAssertEqual(tentative.state.phase, .toolProposed)
        XCTAssertNil(tentative.state.activeAttempt?.toolProposalQueue.first?.approvalSource)
        XCTAssertFalse(effects.contains { if case .executeTool = $0 { return true } else { return false } })
    }

    func testApprovalResolutionRejectsNonUserAuthorityForApprovedCommand() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        applyToolProposalAwaitingApproval(state: &state)
        let forged = ApprovalResolutionPayload(
            decisionID: "d-1",
            approved: true,
            resolutionSource: "policy"
        )
        let draft = makeDraft(
            kind: .approvalResolved,
            sequence: state.lastAppliedSequence + 1,
            expectedLast: state.lastAppliedSequence,
            payload: encoded(forged)
        )

        let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)

        XCTAssertFalse(tentative.isValid)
        XCTAssertEqual(tentative.state.phase, .awaitingApproval)
        XCTAssertNil(tentative.state.activeAttempt?.toolProposalQueue.first?.approvalSource)
        XCTAssertFalse(effects.contains { if case .executeTool = $0 { return true } else { return false } })
    }

    func testApprovalDeniedReturnsToStreamingNonTerminal() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        applyToolProposalAwaitingApproval(state: &state)
        let resolution = ApprovalResolutionPayload(decisionID: "d-1", approved: false, resolutionSource: "user")
        let effects = applyEvent(state: &state, kind: .approvalResolved, payload: encoded(resolution))
        XCTAssertEqual(state.phase, .streaming, "拒绝后回到 streaming")
        XCTAssertNil(state.activeAttempt?.outcome, "拒绝不是 Attempt 终态")
        XCTAssertEqual(state.decisions["d-1"]?.state, .denied)
        XCTAssertTrue(effects.contains(.resolveDecision(decisionID: "d-1", outcome: .denied, source: "user")))
    }

    func testApprovalResolutionRejectsDecisionThatDoesNotOwnActiveProposal() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        applyToolProposalAwaitingApproval(state: &state)
        let forged = ApprovalResolutionPayload(
            decisionID: "forged-decision",
            approved: true,
            resolutionSource: "user"
        )
        let draft = makeDraft(
            kind: .approvalResolved,
            sequence: state.lastAppliedSequence + 1,
            expectedLast: state.lastAppliedSequence,
            payload: encoded(forged)
        )

        let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)

        XCTAssertFalse(tentative.isValid)
        XCTAssertEqual(tentative.state.phase, .awaitingApproval)
        XCTAssertEqual(tentative.state.decisions["d-1"]?.state, .pending)
        XCTAssertFalse(effects.contains { if case .executeTool = $0 { return true } else { return false } })
    }

    // MARK: - approvalExpired / workModeDenied 语义

    func testApprovalExpiredIsNotAttemptTerminalReason() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        applyToolProposalAwaitingApproval(state: &state)
        XCTAssertEqual(state.phase, .awaitingApproval)
        let expired = DecisionExpiredPayload(decisionID: "d-1")
        let effects = applyEvent(state: &state, kind: .decisionExpired, payload: encoded(expired))
        XCTAssertEqual(state.phase, .streaming, "approvalExpired 后 Attempt 回到 streaming")
        XCTAssertNil(state.activeAttempt?.outcome, "approvalExpired 不是 Attempt 终态 reasonCode")
        XCTAssertNil(state.activeAttempt?.error)
        XCTAssertEqual(state.decisions["d-1"]?.state, .expired)
        XCTAssertTrue(effects.contains(.resolveDecision(decisionID: "d-1", outcome: .expired, source: "approvalExpired")))
    }

    func testWorkModeDeniedSettlesProposalOnly() {
        // workModeDenied 只能结算 proposal/decision；不得把 Attempt 推进到终态，也不得伪造 terminal reasonCode
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        applyToolProposalAwaitingApproval(state: &state)
        let resolution = ApprovalResolutionPayload(
            decisionID: "d-1", approved: false, resolutionSource: "workModeDenied"
        )
        let effects = applyEvent(state: &state, kind: .approvalResolved, payload: encoded(resolution))
        XCTAssertEqual(state.phase, .streaming, "workModeDenied 后 Attempt 保持非终态")
        XCTAssertNil(state.activeAttempt?.outcome, "workModeDenied 不得伪造 Attempt 终态")
        XCTAssertNil(state.activeAttempt?.error)
        XCTAssertFalse(
            state.activeAttempt.map { PhaseTransitionTable.isTerminal($0.phase) } ?? true,
            "workModeDenied 不得把 Attempt 置为终态"
        )
        XCTAssertEqual(state.decisions["d-1"]?.state, .denied)
        XCTAssertEqual(state.decisions["d-1"]?.resolutionSource, "workModeDenied")
        XCTAssertTrue(effects.contains(.resolveDecision(decisionID: "d-1", outcome: .denied, source: "workModeDenied")))
        // 没有 finalizeAttempt effect（没有伪造终态 reasonCode）
        XCTAssertFalse(effects.contains { if case .finalizeAttempt = $0 { return true } else { return false } })
    }

    // MARK: - 非法边拒绝

    func testIllegalEdgesRejectedByTransitionTable() {
        // preparing 未排队/未启动直接完成 → 拒绝
        var state = makeState(attempt: makeAttempt(phase: .preparing))
        let completed = AttemptTerminationPayload(outcome: .completed, reasonCode: .completed)
        var draft = makeDraft(kind: .attemptCompleted, payload: encoded(completed))
        var (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertFalse(tentative.isValid, "preparing 直接 completed 是非法边")
        XCTAssertEqual(state.phase, .preparing, "非法边不得改变状态")

        // streaming 直接接管（未持有可移交 handle）→ 拒绝（takeover 只从 executingTool）
        state = makeState(attempt: makeAttempt(phase: .streaming))
        draft = makeDraft(kind: .takeoverRequested)
        (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertFalse(tentative.isValid, "streaming 直接 takeover 是非法边")

        // attemptCancelled 只允许从 stopping；streaming 直接取消 → 拒绝
        state = makeState(attempt: makeAttempt(phase: .streaming))
        draft = makeDraft(kind: .attemptCancelled)
        (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertFalse(tentative.isValid, "streaming 直接 cancelled 是非法边（必须先 Stopping）")

        // startingRuntime 未经 runtimeStarted 不得投影 streaming
        state = makeState(attempt: makeAttempt(phase: .startingRuntime))
        draft = makeDraft(kind: .toolProposed)
        (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertFalse(tentative.isValid, "startingRuntime 直接 toolProposed 是非法边")
    }

    func testTerminalStateRejectsAttemptTransitionsButAllowsNewAttempt() {
        var state = makeState(attempt: makeAttempt(phase: .completed, purpose: .initial))
        // 终态后 attempt 级转移拒绝
        let draft = makeDraft(kind: .toolProposed)
        let (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertFalse(tentative.isValid, "终态 Attempt 不接受转移")

        // Retry：attemptStarted 创建新 Attempt 从 preparing
        state = makeState(attempt: makeAttempt(phase: .completed, purpose: .initial))
        let effects = applyEvent(state: &state, kind: .attemptStarted)
        XCTAssertEqual(state.phase, .preparing, "新 Attempt 从 preparing 开始")
        XCTAssertEqual(state.activeTurn?.attempts.count, 2, "旧 Attempt 保留")
        XCTAssertEqual(state.activeAttempt?.purpose, .retrySameConfig)
        XCTAssertTrue(effects.contains(.requestAdmission(sessionID: "c-1", turnID: "t-1", attemptID: "a-2")))
    }

    func testOrdinaryRetryReusesPreviousAttemptConfigurationSnapshots() {
        var previous = makeAttempt(phase: .completed, purpose: .initial, workMode: .plan)
        previous.runtimeSnapshot = "frozen-model"
        previous.policySnapshot = "frozen-policy"
        previous.toolCapabilitySnapshot = "frozen-tools"
        previous.instructionSnapshot = "frozen-instructions"
        previous.instructionDigest = "sha256:frozen"
        previous.usageBudgetSnapshot = "frozen-budget"
        previous.configurationRevisionDigest = "sha256:configuration"
        previous.targetBindingSnapshot = TargetBinding(
            id: "old-target",
            revision: 7,
            digest: "old-digest",
            connectionID: "old-runtime",
            connectionKind: "ssh",
            remoteIdentity: "old@host",
            hostKeyFingerprint: "old-fingerprint",
            host: "old-host",
            user: "old",
            port: 22,
            targetWorkingDirectory: "/old"
        )
        previous.targetRuntimeGeneration = 41
        previous.terminalModeSnapshot = "backgroundVirtualTerminal"

        var changedSession = makeSession(workMode: .answerOnly)
        changedSession.runtimeSelection.modelID = "new-model-must-not-leak"
        changedSession.targetBinding = TargetBinding(
            id: "new-target",
            revision: 1,
            digest: "new-digest",
            connectionID: "new-runtime",
            connectionKind: "local",
            remoteIdentity: "new",
            hostKeyFingerprint: nil,
            host: "localhost",
            user: "user",
            port: 0,
            targetWorkingDirectory: "/new"
        )
        var state = makeState(session: changedSession, attempt: previous)

        _ = applyEvent(state: &state, kind: .attemptStarted)

        let retried = state.activeAttempt
        XCTAssertEqual(retried?.purpose, .retrySameConfig)
        XCTAssertEqual(retried?.runtimeSnapshot, "frozen-model")
        XCTAssertEqual(retried?.workModeSnapshot, .plan)
        XCTAssertEqual(retried?.policySnapshot, "frozen-policy")
        XCTAssertEqual(retried?.toolCapabilitySnapshot, "frozen-tools")
        XCTAssertEqual(retried?.instructionSnapshot, "frozen-instructions")
        XCTAssertEqual(retried?.instructionDigest, "sha256:frozen")
        XCTAssertEqual(retried?.usageBudgetSnapshot, "frozen-budget")
        XCTAssertEqual(retried?.configurationRevisionDigest, "sha256:configuration")
        XCTAssertEqual(retried?.targetBindingSnapshot?.connectionID, "old-runtime")
        XCTAssertEqual(retried?.targetRuntimeGeneration, 41)
        XCTAssertEqual(retried?.terminalModeSnapshot, "backgroundVirtualTerminal")
    }

    // MARK: - 终态路径

    func testStoppingPathEndsInCancelled() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        _ = applyEvent(state: &state, kind: .interruptRequested)
        XCTAssertEqual(state.phase, .stopping)
        let effects = applyEvent(state: &state, kind: .attemptCancelled)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertTrue(PhaseTransitionTable.isTerminal(state.phase))
        XCTAssertTrue(effects.contains(.finalizeAttempt(attemptID: "a-1", outcome: .cancelled, reasonCode: .cancelled)))
    }

    func testTakeoverPathEndsInTakenOver() {
        var (state, evidence) = makeAutomaticApprovalState()
        _ = applyEvent(
            state: &state,
            kind: .approvalNotRequired,
            payload: encoded(evidence)
        )
        XCTAssertEqual(state.phase, .executingTool)
        _ = applyEvent(state: &state, kind: .takeoverRequested)
        XCTAssertEqual(state.phase, .takeoverPending)
        _ = applyEvent(state: &state, kind: .attemptTakenOver)
        XCTAssertEqual(state.phase, .takenOver)
        XCTAssertTrue(PhaseTransitionTable.isTerminal(state.phase))
    }

    func testAdmissionWaitExpiredFailsWithCapacityWaitExpired() {
        var state = makeState(attempt: makeAttempt(phase: .preparing))
        _ = applyEvent(state: &state, kind: .admissionRequested)
        XCTAssertEqual(state.phase, .waitingForCapacity)
        let effects = applyEvent(state: &state, kind: .admissionWaitExpired)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.activeAttempt?.outcome, .failed)
        XCTAssertTrue(effects.contains(.finalizeAttempt(attemptID: "a-1", outcome: .failed, reasonCode: .capacityWaitExpired)))
    }

    func testRuntimeStartFailureFailsWithRuntimeStartFailed() {
        var state = makeState(attempt: makeAttempt(phase: .waitingForCapacity))
        _ = applyEvent(state: &state, kind: .admissionGranted)
        XCTAssertEqual(state.phase, .startingRuntime)
        let failed = AttemptTerminationPayload(outcome: .failed, reasonCode: .runtimeStartFailed)
        _ = applyEvent(state: &state, kind: .attemptFailed, payload: encoded(failed))
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.activeAttempt?.outcome, .failed)
        XCTAssertEqual(state.activeAttempt?.error, "runtimeStartFailed")
    }

    func testWaitingForCapacityDirectCancel() {
        var state = makeState(attempt: makeAttempt(phase: .preparing))
        _ = applyEvent(state: &state, kind: .admissionRequested)
        XCTAssertEqual(state.phase, .waitingForCapacity)
        _ = applyEvent(state: &state, kind: .admissionCancelled)
        XCTAssertEqual(state.phase, .cancelled, "尚未启动的排位可直接取消")
    }

    func testPauseResumeCycle() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        _ = applyEvent(state: &state, kind: .pauseRequested)
        XCTAssertEqual(state.phase, .pausing)
        _ = applyEvent(state: &state, kind: .paused)
        XCTAssertEqual(state.phase, .paused)
        _ = applyEvent(state: &state, kind: .resumeRequested)
        XCTAssertEqual(state.phase, .streaming)
    }

    func testUserInputCycle() {
        var state = makeState(attempt: makeAttempt(phase: .streaming))
        _ = applyEvent(state: &state, kind: .userInputRequested)
        XCTAssertEqual(state.phase, .awaitingUser)
        let resolved = UserInputResolutionPayload(decisionID: "d-1", nonSensitiveResponse: "answer")
        _ = applyEvent(state: &state, kind: .userInputResolved, payload: encoded(resolved))
        XCTAssertEqual(state.phase, .streaming)
    }

    // MARK: - answer-only 裁剪

    func testAnswerOnlyPrunesToolApprovalSecureInputChildTaskPauseTakeover() {
        // answer-only Attempt 从 preparing 走 排队→启动→流式；Tool/Approval/Execution/
        // SecureInput/ChildTask/Pause/Takeover 事件即使从合法 phase 也被裁剪
        var state = makeState(attempt: makeAttempt(phase: .preparing, workMode: .answerOnly))
        _ = applyEvent(state: &state, kind: .admissionRequested)
        _ = applyEvent(state: &state, kind: .admissionGranted)
        _ = applyEvent(state: &state, kind: .runtimeStarted)
        XCTAssertEqual(state.phase, .streaming)

        for kind in [ConversationEventKind.toolProposed,
                     .sensitiveInputRequested,
                     .userInputRequested,
                     .pauseRequested,
                     .childTaskStarted] {
            let draft = makeDraft(kind: kind)
            let (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
            XCTAssertFalse(tentative.isValid, "answer-only 下 \(kind) 必须被拒绝")
            XCTAssertEqual(tentative.state.phase, .streaming, "拒绝后状态不得改变")
        }

        // 对照组：agent 模式下这些是从 streaming 出发的合法边（各自独立 fresh 状态）
        for kind in [ConversationEventKind.toolProposed, .userInputRequested, .pauseRequested] {
            let fresh = makeState(attempt: makeAttempt(phase: .streaming, workMode: .agent))
            let draft = makeDraft(kind: kind)
            let (tentative, _) = ConversationReducer.reduce(state: fresh, draft: draft)
            XCTAssertTrue(tentative.isValid, "agent 下 \(kind) 应合法")
        }

        // answer-only 正常完成链（重走一遍）
        var answerOnly = makeState(attempt: makeAttempt(phase: .preparing, workMode: .answerOnly))
        _ = applyEvent(state: &answerOnly, kind: .admissionRequested)
        XCTAssertEqual(answerOnly.phase, .waitingForCapacity)
        let startEffects = applyEvent(state: &answerOnly, kind: .admissionGranted)
        XCTAssertEqual(answerOnly.phase, .startingRuntime)
        XCTAssertEqual(startEffects, [.startRuntime(attemptID: "a-1")])
        _ = applyEvent(state: &answerOnly, kind: .runtimeStarted)
        XCTAssertEqual(answerOnly.phase, .streaming)
        let completed = AttemptTerminationPayload(outcome: .completed, reasonCode: .completed)
        let finalEffects = applyEvent(state: &answerOnly, kind: .attemptCompleted, payload: encoded(completed))
        XCTAssertEqual(answerOnly.phase, .completed)
        // answer-only 完成只产生 finalizeAttempt；不产生 decision/proposal 结算类 effect
        XCTAssertTrue(finalEffects.contains(.finalizeAttempt(attemptID: "a-1", outcome: .completed, reasonCode: .completed)))
        XCTAssertFalse(finalEffects.contains { if case .resolveDecision = $0 { return true } else { return false } })
        XCTAssertFalse(finalEffects.contains { if case .requestAdmission = $0 { return true } else { return false } })
    }

    func testAnswerOnlyNoExecutionOrApprovalPhaseReachable() {
        // 即使误发 approvalRequested，answer-only 也不能进入 awaitingApproval
        let state = makeState(attempt: makeAttempt(phase: .streaming, workMode: .answerOnly))
        let draft = makeDraft(kind: .approvalRequested)
        let (tentative, _) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertFalse(tentative.isValid)
        XCTAssertEqual(tentative.state.phase, .streaming)
        XCTAssertNotEqual(tentative.state.phase, .awaitingApproval)
    }

    // MARK: - 工具

    @discardableResult
    private func applyEvent(
        state: inout ConversationSessionState,
        kind: ConversationEventKind,
        payload: Data = Data(),
        sequence: Int? = nil
    ) -> [EffectCommand] {
        let seq = sequence ?? state.lastAppliedSequence + 1
        let draft = makeDraft(kind: kind, sequence: seq, expectedLast: seq - 1, payload: payload)
        let (tentative, effects) = ConversationReducer.reduce(state: state, draft: draft)
        XCTAssertTrue(tentative.isValid, "\(kind) 应合法（当前 phase: \(state.phase)）")
        state = tentative.state
        return effects
    }
}
