import XCTest
import Foundation
import StacioAgentBridge
@testable import StacioApp

// MARK: - 核心闭环行为测试（P核心闭环·步骤 9）

/// 验证 V2 真实闭环：Composer→Bridge→Actor→Reducer→流式→Timeline。
/// 非布尔值测试——验证真实状态推进、流式内容累积、停止/失败终态、Timeline 增量渲染。
@MainActor
final class V2CoreLoopBehaviorTests: XCTestCase {

    // MARK: - Reducer 流式累积

    /// finalAnswerDelta 应累积到 activeAttempt.partialAnswer。
    func testReducerAccumulatesFinalAnswerDelta() {
        let state = Self.makeInitialState()
        let turnDraft = Self.makeDraft(kind: .turnSubmitted, sequence: 1, expected: 0, payload: Data("你好".utf8))
        let afterTurn = ConversationReducer.reduce(state: state, draft: turnDraft).0
        XCTAssertTrue(afterTurn.isValid, "turnSubmitted 必须有效")

        let delta1 = Self.makeDraft(kind: .finalAnswerDelta, sequence: 2, expected: 1, payload: Data("Hello".utf8))
        let afterDelta1 = ConversationReducer.reduce(state: afterTurn.state, draft: delta1).0
        XCTAssertEqual(afterDelta1.state.activeAttempt?.partialAnswer, "Hello")

        let delta2 = Self.makeDraft(kind: .finalAnswerDelta, sequence: 3, expected: 2, payload: Data(" world".utf8))
        let afterDelta2 = ConversationReducer.reduce(state: afterDelta1.state, draft: delta2).0
        XCTAssertEqual(afterDelta2.state.activeAttempt?.partialAnswer, "Hello world")
    }

    /// reasoningSummaryUpdated 应累积到 activeAttempt.reasoningSummary。
    func testReducerAccumulatesReasoningSummary() {
        let state = Self.makeInitialState()
        _ = Self.apply(state: state, kind: .turnSubmitted, sequence: 1, expected: 0, payload: Data("问".utf8))
        let afterReasoning1 = Self.apply(state: state, kind: .turnSubmitted, sequence: 1, expected: 0, payload: Data("问".utf8))
        let reasoningDraft = Self.makeDraft(kind: .reasoningSummaryUpdated, sequence: 2, expected: 1, payload: Data("思考".utf8))
        let afterReasoning = ConversationReducer.reduce(state: afterReasoning1.state, draft: reasoningDraft).0
        XCTAssertEqual(afterReasoning.state.activeAttempt?.reasoningSummary, "思考")
    }

    /// 无活动 Attempt 时 finalAnswerDelta 应记录非法转换（不伪造 Attempt）。
    func testFinalAnswerDeltaWithoutAttemptIsInvalid() {
        let state = Self.makeInitialState()
        let draft = Self.makeDraft(kind: .finalAnswerDelta, sequence: 1, expected: 0, payload: Data("x".utf8))
        let result = ConversationReducer.reduce(state: state, draft: draft).0
        XCTAssertFalse(result.isValid, "无活动 Attempt 时 finalAnswerDelta 必须无效")
    }

    func testTerminalAttemptRejectsLateAnswerAndReasoningMutations() {
        var state = Self.apply(
            state: Self.makeInitialState(),
            kind: .turnSubmitted,
            sequence: 1,
            expected: 0,
            payload: Data("问题".utf8)
        ).state
        for (sequence, kind) in [
            (2, ConversationEventKind.admissionRequested),
            (3, .admissionGranted),
            (4, .runtimeStarted)
        ] {
            state = Self.apply(
                state: state,
                kind: kind,
                sequence: sequence,
                expected: sequence - 1
            ).state
        }
        state = Self.apply(
            state: state,
            kind: .finalAnswerCompleted,
            sequence: 5,
            expected: 4,
            payload: Data("原答案".utf8)
        ).state
        state = Self.apply(
            state: state,
            kind: .attemptCompleted,
            sequence: 6,
            expected: 5
        ).state
        XCTAssertEqual(state.phase, .completed)

        for kind in [
            ConversationEventKind.finalAnswerDelta,
            .finalAnswerCompleted,
            .reasoningSummaryUpdated
        ] {
            let result = Self.apply(
                state: state,
                kind: kind,
                sequence: 7,
                expected: 6,
                payload: Data("迟到内容".utf8)
            )
            XCTAssertFalse(result.isValid, "\(kind.rawValue) 不得修改终态 Attempt")
            XCTAssertEqual(result.state.activeAttempt?.partialAnswer, "原答案")
            XCTAssertNil(result.state.activeAttempt?.reasoningSummary)
        }
    }

    // MARK: - NativeStreamingRuntime（Fake provider 桥接 + 错误映射）

    /// Fake provider 逐 token 回放 → onDelta 收到增量 → onComplete 收到完整消息。
    func testNativeStreamingRuntimeReplaysDeltas() async {
        let provider = FakeStreamingProvider(tokens: ["你", "好", "世界"], finalMessage: "你好世界")
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let request = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: "c-1", turnID: "t-1", attemptID: "a-1",
            targetBindingDigest: "local", targetWorkingDirectory: nil
        )
        let runtime = NativeStreamingRuntime(provider: provider, configuration: config, request: request)

        let completeReceived = XCTestExpectation(description: "complete")
        var collectedDeltas: [String] = []
        var collectedComplete = ""

        runtime.stream(
            userQuestion: "测试",
            onDelta: { delta in collectedDeltas.append(delta) },
            onComplete: { msg in
                collectedComplete = msg
                completeReceived.fulfill()
            },
            onError: { _ in },
            onCancelled: {}
        )

        await fulfillment(of: [completeReceived], timeout: 5, enforceOrder: false)
        XCTAssertEqual(collectedComplete, "你好世界", "完成回调应返回完整消息")
        XCTAssertEqual(collectedDeltas, ["你", "好", "世界"], "应收到全部 delta")
    }

    /// Provider 抛错 → onError 映射为稳定 reasonCode。
    func testNativeStreamingRuntimeMapsError() async {
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "", error: AIAssistantProviderError.httpStatus(401))
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let request = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: "c-1", turnID: "t-1", attemptID: "a-1",
            targetBindingDigest: "local", targetWorkingDirectory: nil
        )
        let runtime = NativeStreamingRuntime(provider: provider, configuration: config, request: request)

        let errorReceived = XCTestExpectation(description: "error")
        var receivedReason: AttemptReasonCode?

        runtime.stream(
            userQuestion: "测试",
            onDelta: { _ in },
            onComplete: { _ in },
            onError: { failure in
                receivedReason = failure.reasonCode
                errorReceived.fulfill()
            },
            onCancelled: {}
        )

        await fulfillment(of: [errorReceived], timeout: 5)
        XCTAssertEqual(receivedReason, .authenticationFailed, "401 应映射为 authenticationFailed")
    }

    func testNativeStreamingRuntimePreservesActionable403ProviderError() async {
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            error: AIAssistantProviderError.apiError(
                statusCode: 403,
                message: "policy denied（请求 ID：req-403）"
            )
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let request = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: "c-1", turnID: "t-1", attemptID: "a-1",
            targetBindingDigest: "local", targetWorkingDirectory: nil
        )
        let runtime = NativeStreamingRuntime(
            provider: provider,
            configuration: config,
            request: request
        )
        let errorReceived = XCTestExpectation(description: "error")
        var receivedFailure: NativeStreamingRuntime.StreamFailure?

        runtime.stream(
            userQuestion: "测试",
            onDelta: { _ in },
            onComplete: { _ in },
            onError: { failure in
                receivedFailure = failure
                errorReceived.fulfill()
            },
            onCancelled: {}
        )

        await fulfillment(of: [errorReceived], timeout: 5)
        XCTAssertEqual(receivedFailure?.reasonCode, .providerRequestFailed)
        XCTAssertTrue(receivedFailure?.summary.contains("供应商拒绝请求") == true)
        XCTAssertTrue(receivedFailure?.summary.contains("req-403") == true)
    }

    /// Native Runtime 的 V2 回调必须保留结构化命令建议，而不是只留下 message。
    func testNativeStreamingRuntimePreservesCommandProposals() async {
        let proposal = AgentCommandProposal(
            id: "proposal-1",
            command: "docker ps",
            explanation: "读取容器状态"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "需要读取状态",
            response: AIAssistantResponse(message: "需要读取状态", commandProposals: [proposal])
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let request = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: "c-1", turnID: "t-1", attemptID: "a-1",
            targetBindingDigest: "local", targetWorkingDirectory: nil
        )
        let runtime = NativeStreamingRuntime(provider: provider, configuration: config, request: request)
        let received = XCTestExpectation(description: "full response")
        var response: AIAssistantResponse?
        runtime.stream(
            userQuestion: "测试",
            onDelta: { _ in },
            onResponse: {
                response = $0
                received.fulfill()
            },
            onError: { _ in },
            onCancelled: {}
        )
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(response?.commandProposals, [proposal])
    }

    func testNativeStreamingRuntimeAppliesFrozenInstructionsAndNeverSendsExcludedTerminalText() async {
        for terminalOutputMode in ["excluded", "summaryOnly"] {
            let recorder = RequestRecorder()
            let provider = FakeStreamingProvider(
                tokens: [],
                finalMessage: "ok",
                requestRecorder: recorder
            )
            let config = ProviderRuntimeConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                apiKey: "test-key"
            )
            let request = NativeAPIRuntimeAction.requestSnapshot(
                conversationID: "c-settings",
                turnID: "t-settings",
                attemptID: "a-settings",
                targetBindingDigest: "local",
                targetWorkingDirectory: "/srv/app"
            )
            let settings = AssistantRuntimeSettingsSnapshot(
                registryRevision: 1,
                valuesByID: [
                    "assistant.instructions.globalText": .string("Only perform read-only checks."),
                    "assistant.context.terminalOutputMode": .string(terminalOutputMode),
                    "assistant.context.autoCompression": .bool(false)
                ]
            )
            let context = AITerminalContext(
                runtimeID: "terminal-1",
                connectionGeneration: 7,
                isConnected: true,
                historyScopeID: "scope-1",
                title: "prod",
                currentDirectory: "/srv/app",
                recentTranscript: "RAW_SECRET_TERMINAL_OUTPUT"
            )
            let runtime = NativeStreamingRuntime(
                provider: provider,
                configuration: config,
                request: request,
                terminalContext: context,
                settings: AppSettings(aiIncludeRecentTerminalTranscript: true),
                assistantSettings: settings,
                allowedToolIDs: []
            )
            let completed = XCTestExpectation(description: "request completed for \(terminalOutputMode)")

            runtime.stream(
                userQuestion: "inspect",
                onDelta: { _ in },
                onComplete: { _ in completed.fulfill() },
                onError: { error in XCTFail("unexpected error: \(error)") },
                onCancelled: { XCTFail("unexpected cancellation") }
            )
            await fulfillment(of: [completed], timeout: 3)

            let captured = await recorder.lastRequest()
            XCTAssertEqual(captured?.additionalInstructions, "Only perform read-only checks.")
            XCTAssertEqual(captured?.context.currentDirectory, "/srv/app")
            if terminalOutputMode == "excluded" {
                XCTAssertEqual(captured?.context.recentTranscript, "")
            } else {
                let transcript = try? XCTUnwrap(captured?.context.recentTranscript)
                XCTAssertTrue(transcript?.contains("[Stacio 终端输出摘要]") == true)
                XCTAssertFalse(transcript?.contains("RAW_SECRET_TERMINAL_OUTPUT") == true)
            }
            XCTAssertEqual(captured?.allowedToolIDs, [])
            XCTAssertFalse(
                captured.map { AIAssistantCoordinator.dynamicContextCharacterCount(in: $0) } == 0,
                "用户问题和指令仍应进入预算"
            )
        }
    }

    func testNativeStreamingRuntimeCancellationWinsAgainstUncooperativeProvider() async {
        let provider = CancellationIgnoringStreamingProvider()
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let request = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: "c-1", turnID: "t-1", attemptID: "a-1",
            targetBindingDigest: "local", targetWorkingDirectory: nil
        )
        let runtime = NativeStreamingRuntime(
            provider: provider,
            configuration: config,
            request: request
        )
        let cancelled = XCTestExpectation(description: "cancelled once")
        var deltas: [String] = []
        var completionCount = 0
        var errorCount = 0
        var cancellationCount = 0

        runtime.stream(
            userQuestion: "测试取消",
            onDelta: { deltas.append($0) },
            onComplete: { _ in completionCount += 1 },
            onError: { _ in errorCount += 1 },
            onCancelled: {
                cancellationCount += 1
                cancelled.fulfill()
            }
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        runtime.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let stillStreaming = runtime.isStreaming
        XCTAssertFalse(stillStreaming)
        XCTAssertEqual(deltas, [])
        XCTAssertEqual(completionCount, 0)
        XCTAssertEqual(errorCount, 0)
        XCTAssertEqual(cancellationCount, 1)
    }

    @MainActor
    func testNativeStreamingRuntimeDeinitCancelsProviderTask() async {
        let provider = CancellationObservingStreamingProvider()
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let request = NativeAPIRuntimeAction.requestSnapshot(
            conversationID: "c-deinit",
            turnID: "t-deinit",
            attemptID: "a-deinit",
            targetBindingDigest: "local",
            targetWorkingDirectory: nil
        )
        var runtime: NativeStreamingRuntime? = NativeStreamingRuntime(
            provider: provider,
            configuration: config,
            request: request
        )
        runtime?.stream(
            userQuestion: "等待取消",
            onDelta: { _ in },
            onComplete: { _ in },
            onError: { _ in },
            onCancelled: {}
        )
        await fulfillment(of: [provider.started], timeout: 3)

        runtime = nil

        await fulfillment(of: [provider.cancelled], timeout: 3)
    }

    // MARK: - SessionRuntimeBridge（真实闭环）

    func testBridgeFailsClosedWhenRuntimeSettingsCannotBeRead() async {
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "must not run",
            requestRecorder: recorder
        )
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            runtimeSettingsProvider: {
                throw AssistantRuntimeSettingsSnapshotError.storeUnavailable
            }
        )

        let result = await bridge.send(text: "do not dispatch")
        let capturedRequest = await recorder.lastRequest()

        XCTAssertEqual(result, .rejected(reason: .settingsUnavailable))
        XCTAssertNil(capturedRequest)
        XCTAssertEqual(actor.currentLastAppliedSequence, 0)
    }

    func testReasoningEffortIsFrozenIntoNextTurnAndProviderRequest() async throws {
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "done",
            requestRecorder: recorder
        )
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: ["assistant.general.defaultReasoningEffort": .string("high")]
        )
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            runtimeSettingsProvider: { settings }
        )

        guard case .accepted = await bridge.send(text: "reason carefully") else {
            return XCTFail("turn should be accepted")
        }
        let deadline = Date().addingTimeInterval(2)
        while await recorder.lastRequest() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let recordedReasoningEffort = await recorder.lastRequest()?.reasoningEffort
        XCTAssertEqual(recordedReasoningEffort, .high)
        XCTAssertEqual(actor.latestPublishedState?.session.runtimeSelection.reasoningEffort, "high")
    }

    func testQueuedInputKeepsSettingsCapturedAtEnqueueTime() async {
        let first = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: ["assistant.instructions.globalText": .string("first-turn")]
        )
        let queued = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: [
                "assistant.instructions.globalText": .string("queued-policy"),
                "assistant.execution.maxToolSteps": .int(11)
            ]
        )
        let later = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: ["assistant.instructions.globalText": .string("later-policy")]
        )
        var current = first
        let provider = FakeStreamingProvider(
            tokens: ["hold"],
            finalMessage: "done",
            perTokenDelay: 5
        )
        let (bridge, _, _) = await Self.makeBridge(
            provider: provider,
            runtimeSettingsProvider: { current }
        )

        guard case .accepted = await bridge.send(text: "first") else {
            return XCTFail("first turn should start")
        }
        current = queued
        let queueResult = await bridge.queue(text: "second")
        XCTAssertEqual(queueResult, .queued(position: 1))
        current = later

        let frozen = bridge.queuedInputs.first?.contextSnapshot.runtimeSettingsSnapshot
        XCTAssertEqual(frozen, queued)
        XCTAssertEqual(frozen?.globalInstructions, "queued-policy")
        XCTAssertEqual(frozen?.maxToolSteps, 11)
        await bridge.stop()
    }

    func testAttemptPersistsPolicyToolInstructionAndUsageSnapshots() async throws {
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 3,
            valuesByID: [
                "assistant.instructions.globalText": .string("frozen instruction"),
                "assistant.tools.enabledToolIDs": .stringArray([StacioBuiltinToolID.terminalCommand]),
                "assistant.execution.maxToolSteps": .int(9),
                "assistant.usage.maxModelInvocations": .int(12)
            ]
        )
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "done")
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            runtimeSettingsProvider: { settings }
        )
        let completed = XCTestExpectation(description: "settings turn completed")
        bridge.onTimelineUpdate = { entries in
            if entries.contains(where: {
                if case .finalAnswer(let text) = $0 { return text == "done" }
                return false
            }) {
                completed.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "capture settings") else {
            return XCTFail("turn should be accepted")
        }
        await fulfillment(of: [completed], timeout: 3)

        let attempt = try XCTUnwrap(actor.latestPublishedState?.activeAttempt)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AssistantRuntimeSettingsSnapshot.self,
                from: Data(attempt.policySnapshot.utf8)
            ),
            settings
        )
        XCTAssertEqual(attempt.instructionSnapshot, "frozen instruction")
        XCTAssertEqual(attempt.instructionDigest, settings.instructionDigest)
        let capabilitySnapshot = try JSONDecoder().decode(
            ToolCapabilitySnapshot.self,
            from: Data(attempt.toolCapabilitySnapshot.utf8)
        )
        XCTAssertEqual(
            capabilitySnapshot.enabledToolIDs,
            [StacioBuiltinToolID.terminalCommand]
        )
        XCTAssertEqual(attempt.toolCatalogRevision, String(capabilitySnapshot.catalogRevision))
        XCTAssertTrue(attempt.usageBudgetSnapshot?.contains("maxModelInvocations") == true)
    }

    func testProviderInvocationLifecycleIsDurableWithoutInventedUsage() async throws {
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "done")
        let (bridge, actor, store) = await Self.makeBridge(provider: provider)
        let completed = XCTestExpectation(description: "provider invocation completed")
        bridge.onTimelineUpdate = { entries in
            if entries.contains(where: {
                if case .finalAnswer(let text) = $0 { return text == "done" }
                return false
            }) {
                completed.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "record invocation") else {
            return XCTFail("turn should be accepted")
        }
        await fulfillment(of: [completed], timeout: 3)

        let invocation = try XCTUnwrap(actor.latestPublishedState?.activeAttempt?.modelInvocations.first)
        XCTAssertEqual(invocation.ordinal, 1)
        XCTAssertNotNil(invocation.endedAt)
        XCTAssertEqual(invocation.outcome, "completed")
        XCTAssertNil(invocation.usage, "Provider 没有返回 usage 时不得伪造 Token 数据")
        XCTAssertTrue(invocation.contextDigest.hasPrefix("sha256:"))

        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        let started = try XCTUnwrap(kinds.firstIndex(of: .modelInvocationStarted))
        let ended = try XCTUnwrap(kinds.firstIndex(of: .modelInvocationCompleted))
        let attemptEnded = try XCTUnwrap(kinds.firstIndex(of: .attemptCompleted))
        XCTAssertLessThan(started, ended)
        XCTAssertLessThan(ended, attemptEnded)
    }

    func testFrozenMaxModelInvocationsStopsBeforeSecondProviderRequest() async {
        let proposal = AgentCommandProposal(
            id: "proposal-model-limit",
            command: "printf one",
            explanation: "first request"
        )
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "first", commandProposals: [proposal]),
                AIAssistantResponse(message: "must not run", commandProposals: [])
            ],
            requestRecorder: recorder
        )
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: [
                "assistant.usage.maxModelInvocations": .int(1),
                "assistant.tools.enabledToolIDs": .stringArray([StacioBuiltinToolID.terminalCommand])
            ]
        )
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            runtimeSettingsProvider: { settings }
        )
        let decision = XCTestExpectation(description: "first provider request proposes a tool")
        let failed = XCTestExpectation(description: "second provider request is blocked")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        bridge.onRuntimeUnavailable = { message in
            if message.contains("模型调用次数已达到本轮上限") { failed.fulfill() }
        }

        guard case .accepted = await bridge.send(text: "one model invocation only") else {
            return XCTFail("turn should be accepted")
        }
        await fulfillment(of: [decision], timeout: 3)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: false
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [failed], timeout: 3)

        let requestCount = await recorder.count()
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.modelInvocations.count, 1)
        XCTAssertEqual(
            actor.latestPublishedState?.activeAttempt?.error,
            AttemptReasonCode.modelInvocationLimitReached.rawValue
        )
    }

    func testApprovalDeadlineExpiresDurablyAndResumesWithoutExecutingTool() async throws {
        let proposal = AgentCommandProposal(
            id: "proposal-expiring",
            command: "printf must-not-run",
            explanation: "deadline test"
        )
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "needs approval", commandProposals: [proposal]),
                AIAssistantResponse(message: "expired safely", commandProposals: [])
            ],
            requestRecorder: recorder
        )
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: [
                "assistant.execution.approvalDeadlineMinutes": .int(0),
                "assistant.tools.enabledToolIDs": .stringArray([StacioBuiltinToolID.terminalCommand])
            ]
        )
        let executor = FakeV2CommandExecutor()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            runtimeSettingsProvider: { settings }
        )
        let decisionShown = XCTestExpectation(description: "deadline-bearing decision is shown")
        let completed = XCTestExpectation(description: "provider resumes after expiry")
        bridge.onToolDecisionUpdate = { decision in
            if decision?.proposalID == proposal.id, decision?.deadline != nil {
                decisionShown.fulfill()
            }
        }
        bridge.onTimelineUpdate = { entries in
            if entries.contains(where: {
                if case .finalAnswer(let text) = $0 { return text == "expired safely" }
                return false
            }) {
                completed.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "expire this approval") else {
            return XCTFail("turn should be accepted")
        }
        await fulfillment(of: [decisionShown, completed], timeout: 3)

        let decision = try XCTUnwrap(actor.latestPublishedState?.decisions.values.first)
        XCTAssertEqual(decision.state, .expired)
        XCTAssertGreaterThan(decision.createdAt.timeIntervalSince1970, 0)
        XCTAssertEqual(decision.deadline, decision.createdAt)
        XCTAssertEqual(executor.runCount, 0)
        let requestCount = await recorder.count()
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .decisionExpired })
        XCTAssertFalse(store.committed.flatMap(\.candidates).contains { $0.kind == .toolStarted })
    }

    func testEffectiveExecutionDeadlineCancelsRuntimeAndFailsDurably() async throws {
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: ["partial"],
            finalMessage: "must not complete",
            perTokenDelay: 5,
            requestRecorder: recorder
        )
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: ["assistant.execution.maxEffectiveMinutes": .int(0)]
        )
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            runtimeSettingsProvider: { settings }
        )
        let expired = XCTestExpectation(description: "effective execution deadline expires")
        bridge.onRuntimeUnavailable = { message in
            if message.contains("有效执行时间已达到上限") { expired.fulfill() }
        }

        guard case .accepted = await bridge.send(text: "respect effective time") else {
            return XCTFail("turn should be accepted")
        }
        await fulfillment(of: [expired], timeout: 3)

        let attempt = try XCTUnwrap(actor.latestPublishedState?.activeAttempt)
        XCTAssertEqual(attempt.phase, .failed)
        XCTAssertEqual(attempt.error, AttemptReasonCode.executionTimeExpired.rawValue)
        XCTAssertNotNil(attempt.endedAt)
        XCTAssertEqual(attempt.modelInvocations.first?.outcome, "expired")
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .executionTimeExpired })
        XCTAssertTrue(bridge.queueAutoAdvancePaused)
    }

    func testFrozenMaxToolStepsStopsASecondToolRound() async {
        let firstProposal = AgentCommandProposal(
            id: "proposal-limit-1",
            command: "printf first",
            explanation: "first"
        )
        let secondProposal = AgentCommandProposal(
            id: "proposal-limit-2",
            command: "printf second",
            explanation: "second"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "first", commandProposals: [firstProposal]),
                AIAssistantResponse(message: "second", commandProposals: [secondProposal])
            ]
        )
        let settings = AssistantRuntimeSettingsSnapshot(
            registryRevision: 1,
            valuesByID: [
                "assistant.execution.maxToolSteps": .int(1),
                "assistant.tools.enabledToolIDs": .stringArray([StacioBuiltinToolID.terminalCommand])
            ]
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context,
            runtimeSettingsProvider: { settings }
        )
        let decision = XCTestExpectation(description: "first tool approval")
        let failed = XCTestExpectation(description: "tool limit failure")
        var sawFailure = false
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == firstProposal.id { decision.fulfill() }
        }
        bridge.onTimelineUpdate = { entries in
            guard sawFailure == false,
                  entries.contains(where: {
                    if case .errorRecovery(let text) = $0 {
                        return text.contains("工具调用轮次超过安全上限")
                    }
                    return false
                  }) else { return }
            sawFailure = true
            failed.fulfill()
        }

        guard case .accepted = await bridge.send(text: "run one tool only") else {
            return XCTFail("turn should be accepted")
        }
        await fulfillment(of: [decision], timeout: 3)
        let resolution = await bridge.resolveToolDecision(
            proposalID: firstProposal.id,
            approved: true
        )
        XCTAssertEqual(
            resolution,
            .accepted
        )
        await fulfillment(of: [failed], timeout: 3)

        XCTAssertEqual(executor.runCount, 1)
        XCTAssertEqual(actor.latestPublishedState?.phase, .failed)
    }

    func testAgentTurnStagesOnlyTheFirstCommandFromOneModelResponse() async throws {
        let firstProposal = AgentCommandProposal(
            id: "proposal-single-step-1",
            command: "printf first",
            explanation: "先读取第一项"
        )
        let secondProposal = AgentCommandProposal(
            id: "proposal-single-step-2",
            command: "printf second",
            explanation: "必须等待第一项结果"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "需要执行检查",
            response: AIAssistantResponse(
                message: "需要执行检查",
                commandProposals: [firstProposal, secondProposal]
            )
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "only first tool waits for approval")
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                if value?.proposalID == firstProposal.id {
                    decision.fulfill()
                }
            }
        }

        guard case .accepted = await bridge.send(text: "按顺序检查") else {
            return XCTFail("turn should be accepted")
        }
        await fulfillment(of: [decision], timeout: 3)

        let queue = try XCTUnwrap(actor.latestPublishedState?.activeAttempt?.toolProposalQueue)
        XCTAssertEqual(queue.map(\.id), [firstProposal.id])
        await bridge.stop()
    }

    /// send → actor 收到 turnSubmitted → 状态进 streaming → 流式 delta 累积 → attemptCompleted。
    func testBridgeSendCompletesTurn() async {
        let provider = FakeStreamingProvider(tokens: ["答", "案"], finalMessage: "答案")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider)

        let timelineExpectation = XCTestExpectation(description: "timeline update with completed answer")
        var lastEntries: [TimelineSourceEntry] = []

        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                lastEntries = entries
                if entries.contains(where: { if case .finalAnswer = $0 { return true }; return false }) {
                    timelineExpectation.fulfill()
                }
            }
        }
        _ = await bridge.send(text: "问题")

        await fulfillment(of: [timelineExpectation], timeout: 5)
        let lastApplied = actor.currentLastAppliedSequence
        XCTAssertGreaterThan(lastApplied, 0, "Actor 必须推进 lastAppliedSequence")
        // 最终回答应出现在 timeline
        XCTAssertTrue(lastEntries.contains { if case .finalAnswer(let t) = $0 { return t.contains("答案") }; return false },
                      "Timeline 应包含最终回答")
    }

    /// send 中 stop → 取消 → attemptCancelled 终态。
    func testBridgeStopCancelsTurn() async {
        // 慢速 provider：第一个 token 延迟，给 stop 留窗口
        let provider = FakeStreamingProvider(tokens: ["x"], finalMessage: "x", perTokenDelay: 0.5)
        let (bridge, actor, _) = await Self.makeBridge(provider: provider)

        let cancelledExpectation = XCTestExpectation(description: "cancelled state")
        var sawCancelled = false

        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: { if case .planProgress(let t) = $0 { return t == "已停止" }; return false }) {
                    sawCancelled = true
                    cancelledExpectation.fulfill()
                }
            }
        }
        _ = await bridge.send(text: "问题")
        try? await Task.sleep(nanoseconds: 50_000_000)
        await bridge.stop()

        await fulfillment(of: [cancelledExpectation], timeout: 5)
        XCTAssertTrue(sawCancelled, "停止后应进入已停止状态")
        let lastApplied = actor.currentLastAppliedSequence
        XCTAssertGreaterThan(lastApplied, 0, "Actor 必须记录停止事件")
    }

    /// Provider 错误 → attemptFailed 终态 + timeline 显示失败。
    func testBridgeProviderErrorFailsTurn() async {
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "", error: AIAssistantProviderError.httpStatus(401))
        let (bridge, actor, _) = await Self.makeBridge(provider: provider)

        let failedExpectation = XCTestExpectation(description: "failed state")
        var sawFailed = false

        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: { if case .errorRecovery(let t) = $0 { return t.contains("失败") }; return false }) {
                    sawFailed = true
                    failedExpectation.fulfill()
                }
            }
        }
        _ = await bridge.send(text: "问题")

        await fulfillment(of: [failedExpectation], timeout: 5)
        XCTAssertTrue(sawFailed, "Provider 401 后应进入失败状态")
        // Actor 状态应为 failed
        let latest = actor.latestPublishedState
        XCTAssertEqual(latest?.phase, .failed, "Attempt 终态必须为 failed")
    }

    /// Tool proposal 必须先 durable + Decision Card，未批准前执行器不能被调用。
    func testBridgeToolProposalWaitsForApproval() async {
        let proposal = AgentCommandProposal(
            id: "proposal-approval",
            command: "docker ps",
            explanation: "读取容器状态"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "需要读取状态",
            responses: [
                AIAssistantResponse(message: "需要读取状态", commandProposals: [proposal]),
                AIAssistantResponse(message: "已完成检查", commandProposals: [])
            ]
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor
        )
        let decision = XCTestExpectation(description: "approval decision")
        var pending: PendingToolDecisionPresentation?
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                guard let value else { return }
                pending = value
                decision.fulfill()
            }
        }
        let result = await bridge.send(text: "检查容器")
        if case .accepted = result {} else { XCTFail("带工具建议的首轮应 accepted") }
        await fulfillment(of: [decision], timeout: 5)
        XCTAssertEqual(pending?.proposalID, proposal.id)
        XCTAssertEqual(pending?.command, proposal.command)
        XCTAssertEqual(pending?.targetWorkingDirectory, "~")
        XCTAssertEqual(pending?.executionDestination, "真实终端")
        XCTAssertEqual(pending?.targetBindingDigest, "d1")
        XCTAssertTrue(pending?.immutableSummary.hasPrefix("sha256:") == true)
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0, "未批准前不得调用执行器")
        XCTAssertEqual(actor.latestPublishedState?.phase, .awaitingApproval)
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .toolProposed })
    }

    func testReadOnlyPolicyAutoExecutesAfterDurableApprovalNotRequired() async {
        let proposal = AgentCommandProposal(
            id: "proposal-auto-readonly",
            command: "uptime",
            explanation: "读取系统运行时间"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "读取状态", commandProposals: [proposal]),
                AIAssistantResponse(message: "检查完成", commandProposals: [])
            ]
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            terminalAutomationPolicyProvider: { runtimeID in
                runtimeID == context.runtimeID
                    ? SessionAutomationPolicy(
                        environment: "development",
                        aiExecutionPolicy: "readOnlyAuto"
                    )
                    : nil
            },
            settingsProvider: {
                AppSettings(agentConfirmationPolicy: .requireEveryCommand)
            },
            initialTargetContext: context
        )

        let completed = expectation(description: "automatic tool round completes")
        bridge.onTimelineUpdate = { entries in
            if entries.contains(where: {
                if case .finalAnswer(let text) = $0 { return text == "检查完成" }
                return false
            }) {
                completed.fulfill()
            }
        }
        guard case .accepted = await bridge.send(text: "检查系统") else {
            return XCTFail("read-only automatic turn should be accepted")
        }
        await fulfillment(of: [completed], timeout: 5)

        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        XCTAssertTrue(kinds.contains(.approvalNotRequired))
        XCTAssertFalse(kinds.contains(.approvalRequested))
        XCTAssertEqual(executor.runCount, 1)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        guard case .runCommand(let request) = executor.requests.first?.action else {
            return XCTFail("automatic path must reach terminal.command")
        }
        XCTAssertEqual(request.approvalEvidence, .policyAutoAllowed)
    }

    func testRepeatedSuccessfulToolCommandIsNotExecutedAgain() async {
        let firstProposal = AgentCommandProposal(
            id: "proposal-repeat-first",
            command: "uptime",
            explanation: "读取系统运行时间"
        )
        let secondProposal = AgentCommandProposal(
            id: "proposal-repeat-second",
            command: "uptime",
            explanation: "再次确认系统运行时间"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "读取状态", commandProposals: [firstProposal]),
                AIAssistantResponse(message: "仍需确认", commandProposals: [secondProposal])
            ]
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            terminalAutomationPolicyProvider: { runtimeID in
                runtimeID == context.runtimeID
                    ? SessionAutomationPolicy(
                        environment: "development",
                        aiExecutionPolicy: "readOnlyAuto"
                    )
                    : nil
            },
            settingsProvider: {
                AppSettings(agentConfirmationPolicy: .requireEveryCommand)
            },
            initialTargetContext: context
        )

        let completed = expectation(description: "duplicate command is short-circuited")
        bridge.onTimelineUpdate = { entries in
            if entries.contains(where: {
                guard case .finalAnswer(let text) = $0 else { return false }
                return text.contains("检测到模型重复请求同一命令")
            }) {
                completed.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "检查系统") else {
            return XCTFail("duplicate command turn should be accepted")
        }
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(executor.runCount, 1, "同一命令在本轮只能进入终端一次")
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
    }

    func testReadOnlyPolicyDoesNotAutoExecuteUnknownExecutable() async {
        let proposal = AgentCommandProposal(
            id: "proposal-unknown-command",
            command: "./vendor-health-check --status",
            explanation: "运行未知供应商脚本"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "运行检查", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            terminalAutomationPolicyProvider: { _ in
                SessionAutomationPolicy(
                    environment: "development",
                    aiExecutionPolicy: "readOnlyAuto"
                )
            },
            settingsProvider: {
                AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt)
            },
            initialTargetContext: context
        )

        let decision = expectation(description: "unknown command awaits approval")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        _ = await bridge.send(text: "运行供应商检查")
        await fulfillment(of: [decision], timeout: 5)

        XCTAssertEqual(actor.latestPublishedState?.phase, .awaitingApproval)
        XCTAssertEqual(executor.runCount, 0)
        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        XCTAssertTrue(kinds.contains(.approvalRequested))
        XCTAssertFalse(kinds.contains(.approvalNotRequired))
    }

    func testReadOnlyPolicyStillRequiresApprovalForWriteCommand() async {
        let proposal = AgentCommandProposal(
            id: "proposal-readonly-write",
            command: "mkdir -p /tmp/stacio-policy-test",
            explanation: "创建测试目录"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "需要写入", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            terminalAutomationPolicyProvider: { _ in
                SessionAutomationPolicy(
                    environment: "development",
                    aiExecutionPolicy: "readOnlyAuto"
                )
            },
            settingsProvider: {
                AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt)
            },
            initialTargetContext: context
        )

        let decision = expectation(description: "write command awaits approval")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        guard case .accepted = await bridge.send(text: "创建目录") else {
            return XCTFail("write turn should be accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        XCTAssertEqual(actor.latestPublishedState?.phase, .awaitingApproval)
        XCTAssertEqual(executor.runCount, 0)
        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        XCTAssertTrue(kinds.contains(.approvalRequested))
        XCTAssertFalse(kinds.contains(.approvalNotRequired))
    }

    func testProductionPolicyAlwaysRequiresApprovalForReadOnlyCommand() async {
        let proposal = AgentCommandProposal(
            id: "proposal-production-readonly",
            command: "uptime",
            explanation: "读取系统运行时间"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "读取生产状态", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            terminalAutomationPolicyProvider: { _ in
                SessionAutomationPolicy(
                    environment: "production",
                    aiExecutionPolicy: "readOnlyAuto"
                )
            },
            settingsProvider: {
                AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt)
            },
            initialTargetContext: context
        )

        let decision = expectation(description: "production awaits approval")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        _ = await bridge.send(text: "检查生产系统")
        await fulfillment(of: [decision], timeout: 5)
        XCTAssertEqual(actor.latestPublishedState?.phase, .awaitingApproval)
        XCTAssertEqual(executor.runCount, 0)
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains {
            $0.kind == .approvalRequested
        })
    }

    func testCurrentStricterPolicyPreventsFrozenAutoApproval() async {
        let proposal = AgentCommandProposal(
            id: "proposal-policy-tightened",
            command: "uptime",
            explanation: "读取系统运行时间"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "读取状态", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        final class PolicyBox {
            var value = SessionAutomationPolicy(
                environment: "development",
                aiExecutionPolicy: "readOnlyAuto"
            )
        }
        let policyBox = PolicyBox()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            terminalAutomationPolicyProvider: { _ in policyBox.value },
            settingsProvider: {
                AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt)
            },
            initialTargetContext: context
        )
        policyBox.value = SessionAutomationPolicy(
            environment: "production",
            aiExecutionPolicy: "readOnlyAuto"
        )

        let decision = expectation(description: "tightened policy awaits approval")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        _ = await bridge.send(text: "检查状态")
        await fulfillment(of: [decision], timeout: 5)
        XCTAssertEqual(actor.latestPublishedState?.phase, .awaitingApproval)
        XCTAssertEqual(executor.runCount, 0)
        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        XCTAssertTrue(kinds.contains(.approvalRequested))
        XCTAssertFalse(kinds.contains(.approvalNotRequired))
    }

    func testDenyPatternCancelsProposalWithoutExecutingOrRequestingApproval() async {
        let proposal = AgentCommandProposal(
            id: "proposal-deny-pattern",
            command: "rm -rf /tmp/stacio-denied",
            explanation: "不应执行"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "尝试执行", commandProposals: [proposal]),
                AIAssistantResponse(message: "命令已被策略阻止", commandProposals: [])
            ]
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            terminalAutomationPolicyProvider: { _ in .default },
            settingsProvider: {
                AppSettings(
                    agentConfirmationPolicy: .allowAllWithoutPrompt,
                    agentCommandDenyPatterns: "rm -rf"
                )
            },
            initialTargetContext: context
        )

        let completed = expectation(description: "provider resumes after policy denial")
        bridge.onTimelineUpdate = { entries in
            if entries.contains(where: {
                if case .finalAnswer(let text) = $0 { return text == "命令已被策略阻止" }
                return false
            }) {
                completed.fulfill()
            }
        }
        _ = await bridge.send(text: "删除测试目录")
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(executor.runCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        XCTAssertTrue(kinds.contains(.toolProposalCancelled))
        XCTAssertFalse(kinds.contains(.approvalRequested))
        XCTAssertFalse(kinds.contains(.approvalNotRequired))
    }

    func testAutoApprovalKeepsExecutionDestinationFrozenForActiveTurn() async {
        let proposal = AgentCommandProposal(
            id: "proposal-auto-frozen-destination",
            command: "uptime",
            explanation: "读取系统状态"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "读取状态", commandProposals: [proposal]),
                AIAssistantResponse(message: "完成", commandProposals: [])
            ]
        )
        let executor = FakeV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let capture = ExecutionChoiceCapture()
        let (bridge, _, _) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            executionModeSnapshotHandler: { capture.append($0) },
            terminalAutomationPolicyProvider: { _ in
                SessionAutomationPolicy(
                    environment: "development",
                    aiExecutionPolicy: "readOnlyAuto"
                )
            },
            settingsProvider: {
                AppSettings(agentConfirmationPolicy: .allowAllWithoutPrompt)
            },
            initialTargetContext: context,
            initialExecutionChoice: .backgroundVirtualTerminal
        )
        let completed = expectation(description: "automatic frozen destination completes")
        bridge.onTimelineUpdate = { entries in
            if entries.contains(where: {
                if case .finalAnswer(let text) = $0 { return text == "完成" }
                return false
            }) {
                completed.fulfill()
            }
        }
        _ = await bridge.send(text: "检查系统")
        bridge.setExecutionChoice(.realTerminal)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(capture.last, .backgroundVirtualTerminal)
        XCTAssertEqual(executor.runCount, 1)
    }

    /// 批准后执行器只被调用一次，结果进入会话并继续上游模型。
    func testBridgeApprovalExecutesAndContinuesProvider() async {
        let proposal = AgentCommandProposal(
            id: "proposal-run",
            command: "printf ok",
            explanation: "输出健康检查标记"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "先执行检查", commandProposals: [proposal]),
                AIAssistantResponse(message: "检查完成", commandProposals: [])
            ]
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "approval decision")
        var proposalID: String?
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                guard let value else { return }
                proposalID = value.proposalID
                decision.fulfill()
            }
        }
        _ = await bridge.send(text: "执行检查")
        await fulfillment(of: [decision], timeout: 5)
        guard let proposalID else { return XCTFail("应产生待审批建议") }
        let resolution = await bridge.resolveToolDecision(proposalID: proposalID, approved: true)
        XCTAssertEqual(resolution, .accepted)

        let completed = XCTestExpectation(description: "continued answer")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 { return text == "检查完成" }
                    return false
                }) {
                    completed.fulfill()
                }
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 1)
        guard case .runCommand(let request) = executor.requests.first?.action else {
            return XCTFail("approved path must reach terminal.command")
        }
        XCTAssertEqual(request.approvalEvidence, .userApproved)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .toolStarted })
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .toolProposalResolved })
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty, "完整工具轮次结束后 outbox 必须已结算")
    }

    /// Production traces must materialize an execution card through the real
    /// Bridge projection. The same sanitised evidence is used by the UI and by
    /// durable tool-result events, so a relaunch cannot reveal the original
    /// credential-bearing output.
    func testVisibleTerminalTraceProjectsRedactedExecutionCardAndDurableEvidence() async throws {
        let secret = "trace-secret-123"
        let proposal = AgentCommandProposal(
            id: "proposal-visible-card",
            command: "curl -H Authorization: Bearer \(secret) https://example.invalid/health",
            explanation: "读取健康状态"
        )
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "执行健康检查", commandProposals: [proposal]),
                AIAssistantResponse(message: "检查完成", commandProposals: [])
            ],
            requestRecorder: recorder
        )
        let executor = TraceProjectingV2CommandExecutor(
            executionMode: "visibleTerminal",
            terminalOutput: "Authorization: Bearer \(secret)\nservice: healthy",
            terminalHistoryOutput: "top - 10:49:01 up 1 day\n%Cpu(s): 80.0 us, 20.0 sy\nAuthorization: Bearer \(secret)\nservice: healthy"
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = expectation(description: "visible terminal approval")
        let completed = expectation(description: "visible terminal card projected")
        let finalAnswer = expectation(description: "provider resumed after visible terminal")
        var latestCard: ExecutionCardPresentation?
        var latestTimelineEntries: [TimelineSourceEntry] = []
        var didFulfillCompleted = false
        var didFulfillFinalAnswer = false
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        bridge.onTimelineUpdate = { entries in
            latestTimelineEntries = entries
            for entry in entries {
                if case .executionCard(let card) = entry, card.proposalID == proposal.id {
                    latestCard = card
                    if card.status == "已完成", didFulfillCompleted == false {
                        didFulfillCompleted = true
                        completed.fulfill()
                    }
                }
                if case .finalAnswer(let text) = entry,
                   text == "检查完成",
                   didFulfillFinalAnswer == false {
                    didFulfillFinalAnswer = true
                    finalAnswer.fulfill()
                }
            }
        }

        guard case .accepted = await bridge.send(text: "检查服务") else {
            return XCTFail("工具轮次应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let visibleResolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(visibleResolution, .accepted)
        await fulfillment(of: [completed, finalAnswer], timeout: 5)

        let card = try XCTUnwrap(latestCard)
        XCTAssertTrue(card.isRealTerminal)
        XCTAssertFalse(card.redactedCommand.contains(secret))
        XCTAssertTrue(card.redactedCommand.contains("[redacted]"))
        let artifact = try XCTUnwrap(card.terminalArtifact)
        XCTAssertTrue(artifact.canOpenTerminal)
        XCTAssertFalse(artifact.canCancel)
        XCTAssertTrue(artifact.isFinished, "completed Trace 无退出码时仍必须显示为终态")
        XCTAssertFalse(artifact.liveTail?.contains(secret) ?? true)
        XCTAssertFalse(artifact.redactedLog.contains(secret))
        let executionIndex = try XCTUnwrap(latestTimelineEntries.firstIndex {
            if case .executionCard(let projected) = $0 { return projected.proposalID == proposal.id }
            return false
        })
        let answerIndex = try XCTUnwrap(latestTimelineEntries.firstIndex {
            if case .finalAnswer(let text) = $0 { return text == "检查完成" }
            return false
        })
        XCTAssertLessThan(
            executionIndex,
            answerIndex,
            "持续生成的回答应位于终端执行卡之后，避免终端刷新把回答推出可视区"
        )
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        let resumedRequest = await recorder.lastRequest()
        XCTAssertTrue(
            resumedRequest?.question.contains("%Cpu(s): 80.0 us") == true,
            "工具完成后续答必须拿到已脱敏的完整终端历史，而不是旧登录摘要"
        )

        let durableToolPayloads = store.committed
            .flatMap(\.candidates)
            .filter { $0.kind == .toolCompleted || $0.kind == .toolProposalResolved }
            .compactMap { String(data: $0.payload, encoding: .utf8) }
        XCTAssertFalse(durableToolPayloads.isEmpty)
        XCTAssertFalse(durableToolPayloads.joined().contains(secret))
    }

    func testCompletedToolWithEmptyTerminalOutputPublishesExplicitNoOutputFact() async throws {
        let proposal = AgentCommandProposal(
            id: "proposal-empty-output",
            command: "true",
            explanation: "执行无文本输出的健康检查"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "执行检查", commandProposals: [proposal]),
                AIAssistantResponse(message: "检查完成", commandProposals: [])
            ]
        )
        let executor = TraceProjectingV2CommandExecutor(
            executionMode: "visibleTerminal",
            terminalOutput: ""
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, _, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = expectation(description: "empty output approval")
        let completed = expectation(description: "empty output card projected")
        var latestCard: ExecutionCardPresentation?
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        bridge.onTimelineUpdate = { entries in
            for entry in entries {
                if case .executionCard(let card) = entry, card.proposalID == proposal.id {
                    latestCard = card
                    if card.status == "已完成" {
                        completed.fulfill()
                    }
                }
            }
        }

        guard case .accepted = await bridge.send(text: "检查状态") else {
            return XCTFail("工具轮次应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let decisionResult = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(decisionResult, .accepted)
        await fulfillment(of: [completed], timeout: 5)

        let card = try XCTUnwrap(latestCard)
        XCTAssertEqual(card.terminalArtifact?.liveTail, "命令已完成，但终端没有返回文本输出。")
        let durableToolPayloads = store.committed
            .flatMap(\.candidates)
            .filter { $0.kind == .toolCompleted || $0.kind == .toolProposalResolved }
            .compactMap { String(data: $0.payload, encoding: .utf8) }
        XCTAssertTrue(durableToolPayloads.joined().contains("命令已完成，但终端没有返回文本输出。"))
    }

    func testBackgroundAndUnknownModeTracesNeverExposeOpenTerminalAction() async throws {
        for fixture in [
            (id: "background", mode: Optional("backgroundTask"), choice: TurnExecutionChoice.backgroundVirtualTerminal),
            (id: "legacy", mode: Optional<String>.none, choice: TurnExecutionChoice.realTerminal)
        ] {
            let proposal = AgentCommandProposal(
                id: "proposal-\(fixture.id)",
                command: "printf ok",
                explanation: "验证终端入口边界"
            )
            let provider = FakeStreamingProvider(
                tokens: [],
                finalMessage: "",
                responses: [
                    AIAssistantResponse(message: "执行检查", commandProposals: [proposal]),
                    AIAssistantResponse(message: "完成", commandProposals: [])
                ]
            )
            let executor = TraceProjectingV2CommandExecutor(
                executionMode: fixture.mode,
                terminalOutput: "ok"
            )
            let context = Self.makeVerifiedLocalTerminalContext()
            let (bridge, _, _) = await Self.makeBridge(
                provider: provider,
                executionCoordinator: executor,
                targetContextResolver: { runtimeID in
                    runtimeID == context.runtimeID ? context : nil
                },
                initialTargetContext: context,
                initialExecutionChoice: fixture.choice
            )
            let decision = expectation(description: "\(fixture.id) approval")
            let projected = expectation(description: "\(fixture.id) card")
            var latestCard: ExecutionCardPresentation?
            bridge.onToolDecisionUpdate = { value in
                if value?.proposalID == proposal.id { decision.fulfill() }
            }
            bridge.onTimelineUpdate = { entries in
                for entry in entries {
                    if case .executionCard(let card) = entry,
                       card.proposalID == proposal.id,
                       card.status == "已完成" {
                        latestCard = card
                        projected.fulfill()
                    }
                }
            }
            guard case .accepted = await bridge.send(text: "运行 \(fixture.id)") else {
                return XCTFail("\(fixture.id) 工具轮次应 accepted")
            }
            await fulfillment(of: [decision], timeout: 5)
            let resolution = await bridge.resolveToolDecision(
                proposalID: proposal.id,
                approved: true
            )
            XCTAssertEqual(resolution, .accepted)
            await fulfillment(of: [projected], timeout: 5)
            let card = try XCTUnwrap(latestCard)
            XCTAssertFalse(card.terminalArtifact?.canOpenTerminal ?? true)
            if fixture.mode == "backgroundTask" {
                XCTAssertFalse(card.isRealTerminal)
            }
        }
    }

    func testUnconfirmedExecutionCancellationFailsClosedWithoutCancellingTurn() async throws {
        let proposal = AgentCommandProposal(
            id: "proposal-unconfirmed-cancel",
            command: "tail -f service.log",
            explanation: "持续查看日志"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "开始跟踪", commandProposals: [proposal])
        )
        let executor = UnconfirmedCancellationV2CommandExecutor()
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = expectation(description: "unconfirmed cancellation approval")
        let running = expectation(description: "running execution card")
        var requestID: String?
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id { decision.fulfill() }
        }
        bridge.onTimelineUpdate = { entries in
            for entry in entries {
                if case .executionCard(let card) = entry,
                   card.proposalID == proposal.id,
                   card.status == "执行中",
                   requestID == nil,
                   let activeRequestID = card.terminalArtifact?.requestID {
                    requestID = activeRequestID
                    running.fulfill()
                }
            }
        }
        guard case .accepted = await bridge.send(text: "跟踪日志") else {
            return XCTFail("工具轮次应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [running], timeout: 5)

        let cancelled = await bridge.cancelExecution(requestID: try XCTUnwrap(requestID))
        XCTAssertFalse(cancelled, "协调器无终态证据时不能向 UI 谎报取消成功")
        XCTAssertEqual(actor.latestPublishedState?.phase, .executingTool)
        XCTAssertTrue(try store.loadUnsettledOutbox().contains {
            $0.state == .reconciliationRequired
        })
    }

    /// 升级前的 durable 工具建议没有连接代次。它可以继续展示和结算，
    /// 但批准后必须 fail closed，不能把旧命令写入当前终端。
    func testApprovalWithoutVerifiedGenerationSettlesWithoutExecution() async {
        let proposal = AgentCommandProposal(
            id: "proposal-unverified-generation",
            command: "printf should-not-run",
            explanation: "验证旧审批 fail closed"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "等待批准", commandProposals: [proposal]),
                AIAssistantResponse(message: "连接未验证，命令未执行", commandProposals: [])
            ]
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor
        )
        let decision = XCTestExpectation(description: "unverified approval")
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                if value?.proposalID == proposal.id {
                    XCTAssertNil(value?.targetRuntimeGeneration)
                    decision.fulfill()
                }
            }
        }

        guard case .accepted = await bridge.send(text: "检查旧审批") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)

        let completed = XCTestExpectation(description: "provider resumes after fail closed")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 {
                        return text == "连接未验证，命令未执行"
                    }
                    return false
                }) {
                    completed.fulfill()
                }
            }
        }
        await fulfillment(of: [completed], timeout: 5)

        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty)
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { draft in
            guard draft.kind == .toolProposalResolved,
                  let payload = EventPayloadCodec.decode(
                      ToolProposalResolutionPayload.self,
                      from: draft.payload
                  )
            else { return false }
            return payload.proposalID == proposal.id
                && payload.result == nil
                && payload.error?.contains("连接代次") == true
        })
    }

    /// Decision Card 批准的是冻结的完整 TargetBinding。等待期间即使
    /// runtimeID 被复用，工作目录或终端身份变化也必须拒绝旧命令。
    func testApprovalRejectsReboundTargetBeforeToolExecution() async {
        let originalContext = AITerminalContext(
            runtimeID: "term-reused",
            historyScopeID: "scope-production",
            title: "deploy@production",
            currentDirectory: "/srv/original",
            recentTranscript: ""
        )
        let availability = TargetAvailability(context: originalContext)
        let proposal = AgentCommandProposal(
            id: "proposal-rebound-target",
            command: "printf should-not-run",
            explanation: "验证旧审批不会落到重建后的目标"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "等待批准", commandProposals: [proposal]),
                AIAssistantResponse(message: "目标已变化，未执行命令", commandProposals: [])
            ]
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in availability.resolve(runtimeID) }
        )
        let decision = XCTestExpectation(description: "approval decision")
        await MainActor.run {
            XCTAssertTrue(bridge.setTargetRuntimeID(originalContext.runtimeID))
            bridge.onToolDecisionUpdate = { value in
                if value?.proposalID == proposal.id {
                    decision.fulfill()
                }
            }
        }

        guard case .accepted = await bridge.send(text: "检查生产目录") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        availability.update(AITerminalContext(
            runtimeID: originalContext.runtimeID,
            historyScopeID: originalContext.historyScopeID,
            title: originalContext.title,
            currentDirectory: "/srv/rebound",
            recentTranscript: ""
        ))

        let completed = XCTestExpectation(description: "provider resumes after target rejection")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 {
                        return text == "目标已变化，未执行命令"
                    }
                    return false
                }) {
                    completed.fulfill()
                }
            }
        }
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [completed], timeout: 5)

        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0, "目标变化后不得调用终端执行器")
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty, "拒绝旧目标后 effect 必须以 failed 结算")
        XCTAssertTrue(
            store.committed.flatMap(\.candidates).contains { draft in
                guard draft.kind == .toolProposalResolved,
                      let resolution = EventPayloadCodec.decode(
                          ToolProposalResolutionPayload.self,
                          from: draft.payload
                      ) else { return false }
                return resolution.proposalID == proposal.id
                    && resolution.result == nil
                    && resolution.error?.contains("工作目录已变化") == true
            },
            "必须持久化未执行原因，供恢复与 Provider 后续轮次使用"
        )
    }

    /// 执行协调器缺失时，已 claim 的工具 effect 也必须有确定的终态，
    /// 不能把 outbox 留在 dispatching 并永久卡住会话。
    func testMissingExecutionCoordinatorSettlesToolFailure() async {
        let proposal = AgentCommandProposal(
            id: "proposal-no-executor",
            command: "printf should-not-run",
            explanation: "验证执行器不可用分支"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "先检查", commandProposals: [proposal]),
                AIAssistantResponse(message: "执行器不可用，已安全结束", commandProposals: [])
            ]
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "approval decision")
        var proposalID: String?
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                guard let value else { return }
                proposalID = value.proposalID
                decision.fulfill()
            }
        }
        _ = await bridge.send(text: "检查")
        await fulfillment(of: [decision], timeout: 5)
        guard let proposalID else { return XCTFail("应产生待审批建议") }
        let resolution = await bridge.resolveToolDecision(proposalID: proposalID, approved: true)
        XCTAssertEqual(resolution, .accepted)

        let completed = XCTestExpectation(description: "provider resumes after deterministic tool failure")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 {
                        return text == "执行器不可用，已安全结束"
                    }
                    return false
                }) {
                    completed.fulfill()
                }
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty)
    }

    /// AgentExecutionCoordinator emits a terminal cancellation before throwing
    /// `denied`. The durable result must win over the generic catch path instead
    /// of incorrectly freezing the session as an unknown external write.
    func testTerminalTraceThenCoordinatorErrorSettlesWithoutReconciliationFence() async {
        let proposal = AgentCommandProposal(
            id: "proposal-denied",
            command: "printf should-not-run",
            explanation: "验证拒绝终态结算"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "等待批准", commandProposals: [proposal]),
                AIAssistantResponse(message: "命令已取消，继续给出结论", commandProposals: [])
            ]
        )
        let executor = await MainActor.run { TerminalThenThrowingV2CommandExecutor() }
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "denied proposal")
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                if value?.proposalID == proposal.id {
                    decision.fulfill()
                }
            }
        }
        guard case .accepted = await bridge.send(text: "执行后继续") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)

        let completed = XCTestExpectation(description: "provider resumes after denied execution")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 {
                        return text == "命令已取消，继续给出结论"
                    }
                    return false
                }) {
                    completed.fulfill()
                }
            }
        }
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [completed], timeout: 5)

        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty)
    }

    /// Stop can re-enter the MainActor while `.toolStarted` is waiting on the
    /// session store. The stop owns a deterministic pre-dispatch cancellation:
    /// the terminal coordinator must never receive the command and the claimed
    /// outbox item must still reach a durable settlement.
    func testStopWhileToolStartedCommitIsPendingNeverDispatchesCommand() async {
        let proposal = AgentCommandProposal(
            id: "proposal-stop-before-dispatch",
            command: "printf should-not-run",
            explanation: "验证持久化窗口内停止"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "等待批准", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let store = InMemoryConversationSessionStore()
        let commitReached = XCTestExpectation(description: "toolStarted commit entered store")
        let releaseCommit = DispatchSemaphore(value: 0)
        let gateLock = NSLock()
        var didBlockToolStarted = false
        store.beforeCommit = { candidates in
            guard candidates.contains(where: { $0.kind == .toolStarted }) else { return }
            let shouldBlock = gateLock.withLock {
                guard didBlockToolStarted == false else { return false }
                didBlockToolStarted = true
                return true
            }
            guard shouldBlock else { return }
            commitReached.fulfill()
            _ = releaseCommit.wait(timeout: .now() + 5)
        }

        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let bridge = SessionRuntimeBridge(
            actor: actor,
            sessionID: "c-1",
            initialState: initialState,
            provider: provider,
            providerConfig: ProviderRuntimeConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                apiKey: "test-key"
            ),
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "approval decision")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id {
                decision.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "批准后立即停止") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [commitReached], timeout: 5)

        let releaseTask = Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            releaseCommit.signal()
        }
        await bridge.stop()
        _ = await releaseTask.result

        XCTAssertEqual(executor.runCount, 0, "Stop 发生在外部投递前时不得调用执行器")
        XCTAssertEqual(actor.latestPublishedState?.phase, .cancelled)
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty)
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .toolStarted })
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .toolProposalResolved })
    }

    /// Stop can also arrive one await earlier, while the execute-tool effect is
    /// being claimed and no local dispatch marker exists yet. The claimed item
    /// must be cancelled without committing `.toolStarted` or calling the
    /// terminal coordinator for the superseded generation.
    func testStopWhileToolEffectClaimIsPendingNeverDispatchesCommand() async {
        let proposal = AgentCommandProposal(
            id: "proposal-stop-during-claim",
            command: "printf should-not-run",
            explanation: "验证 effect claim 窗口内停止"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "等待批准", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let store = InMemoryConversationSessionStore()
        let claimReached = XCTestExpectation(description: "execute-tool claim entered store")
        let releaseClaim = DispatchSemaphore(value: 0)
        store.beforeClaimOutboxEffect = { command in
            guard case .executeTool = command else { return }
            claimReached.fulfill()
            _ = releaseClaim.wait(timeout: .now() + 5)
        }

        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let bridge = SessionRuntimeBridge(
            actor: actor,
            sessionID: "c-1",
            initialState: initialState,
            provider: provider,
            providerConfig: ProviderRuntimeConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                apiKey: "test-key"
            ),
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "approval decision")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id {
                decision.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "批准后立即停止") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [claimReached], timeout: 5)

        let releaseTask = Task.detached {
            try? await Task.sleep(nanoseconds: 100_000_000)
            releaseClaim.signal()
        }
        await bridge.stop()
        _ = await releaseTask.result
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(executor.runCount, 0, "Stop 期间取得的旧 effect 不得触发终端执行")
        XCTAssertEqual(actor.latestPublishedState?.phase, .cancelled)
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty)
        XCTAssertFalse(store.committed.flatMap(\.candidates).contains { $0.kind == .toolStarted })
    }

    /// A storage or reconciliation failure can block the session while the
    /// execute-tool effect claim is awaiting the Actor. The returned claim no
    /// longer carries authority to cross the terminal boundary.
    func testSessionBlockWhileToolEffectClaimIsPendingNeverDispatchesCommand() async {
        let proposal = AgentCommandProposal(
            id: "proposal-block-during-claim",
            command: "printf should-not-run",
            explanation: "验证会话保护状态下禁止终端执行"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "等待批准", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let store = InMemoryConversationSessionStore()
        let claimReached = XCTestExpectation(description: "execute-tool claim entered store")
        let releaseClaim = DispatchSemaphore(value: 0)

        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let bridge = SessionRuntimeBridge(
            actor: actor,
            sessionID: "c-1",
            initialState: initialState,
            provider: provider,
            providerConfig: ProviderRuntimeConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                apiKey: "test-key"
            ),
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        store.beforeClaimOutboxEffect = { command in
            guard case .executeTool = command else { return }
            DispatchQueue.main.async {
                bridge.storageError = ConversationStorageError(
                    summary: "测试注入的持久化故障",
                    recoveryHint: "会话进入只读保护"
                )
                releaseClaim.signal()
                claimReached.fulfill()
            }
            _ = releaseClaim.wait(timeout: .now() + 5)
        }
        let decision = XCTestExpectation(description: "approval decision")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id {
                decision.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "批准后触发存储保护") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [claimReached], timeout: 5)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(bridge.isSessionUsable)
        XCTAssertEqual(executor.runCount, 0, "blocked 会话取得的旧 effect 不得触发终端执行")
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty)
        XCTAssertFalse(store.committed.flatMap(\.candidates).contains { $0.kind == .toolStarted })
    }

    /// The final write-ahead event is another suspension boundary. If storage
    /// protection activates while `.toolStarted` is being committed, the
    /// claimed effect is cancelled before the terminal coordinator is called.
    func testSessionBlockWhileToolStartedCommitIsPendingNeverDispatchesCommand() async {
        let proposal = AgentCommandProposal(
            id: "proposal-block-during-tool-start",
            command: "printf should-not-run",
            explanation: "验证 toolStarted 持久化窗口内的会话保护"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "等待批准", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let store = InMemoryConversationSessionStore()
        let commitReached = XCTestExpectation(description: "toolStarted commit entered store")
        let releaseCommit = DispatchSemaphore(value: 0)
        let gateLock = NSLock()
        var didBlockToolStarted = false
        store.beforeCommit = { candidates in
            guard candidates.contains(where: { $0.kind == .toolStarted }) else { return }
            let shouldBlock = gateLock.withLock {
                guard didBlockToolStarted == false else { return false }
                didBlockToolStarted = true
                return true
            }
            guard shouldBlock else { return }
            commitReached.fulfill()
            _ = releaseCommit.wait(timeout: .now() + 5)
        }

        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let bridge = SessionRuntimeBridge(
            actor: actor,
            sessionID: "c-1",
            initialState: initialState,
            provider: provider,
            providerConfig: ProviderRuntimeConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                apiKey: "test-key"
            ),
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "approval decision")
        bridge.onToolDecisionUpdate = { value in
            if value?.proposalID == proposal.id, value?.isActionable == true {
                decision.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "批准后触发存储保护") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [commitReached], timeout: 5)

        bridge.storageError = ConversationStorageError(
            summary: "测试注入的持久化故障",
            recoveryHint: "会话进入只读保护"
        )
        releaseCommit.signal()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(bridge.isSessionUsable)
        XCTAssertEqual(executor.runCount, 0, "blocked 会话不得越过最终持久化边界执行终端命令")
        XCTAssertTrue(store.committed.flatMap(\.candidates).contains { $0.kind == .toolStarted })
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty, "未外发的 effect 必须确定性取消")
    }

    /// A pending approval remains visible for audit/copying after the session
    /// is protected, but it must immediately lose both approve and deny
    /// authority and the bridge must reject stale UI actions as well.
    func testSessionBlockMakesPendingApprovalReadOnlyAndRejectsResolution() async {
        let proposal = AgentCommandProposal(
            id: "proposal-blocked-approval",
            command: "uptime",
            explanation: "验证保护状态下审批失效"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            response: AIAssistantResponse(message: "等待批准", commandProposals: [proposal])
        )
        let executor = FakeV2CommandExecutor()
        let store = InMemoryConversationSessionStore()
        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let bridge = SessionRuntimeBridge(
            actor: actor,
            sessionID: "c-1",
            initialState: initialState,
            provider: provider,
            providerConfig: ProviderRuntimeConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                apiKey: "test-key"
            ),
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        var projectedDecision: PendingToolDecisionPresentation?
        let decision = XCTestExpectation(description: "actionable approval decision")
        bridge.onToolDecisionUpdate = { value in
            projectedDecision = value
            if value?.proposalID == proposal.id, value?.isActionable == true {
                decision.fulfill()
            }
        }

        guard case .accepted = await bridge.send(text: "检查系统负载") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        XCTAssertTrue(projectedDecision?.isActionable == true)

        bridge.storageError = ConversationStorageError(
            summary: "测试注入的持久化故障",
            recoveryHint: "会话进入只读保护"
        )

        XCTAssertEqual(projectedDecision?.proposalID, proposal.id)
        XCTAssertFalse(projectedDecision?.isActionable ?? true)
        XCTAssertTrue(projectedDecision?.statusMessage?.contains("只读保护") == true)
        let resolution = await bridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        guard case .rejected(let reason) = resolution else {
            return XCTFail("blocked 会话必须拒绝审批")
        }
        XCTAssertTrue(reason.contains("只读保护"))
        XCTAssertEqual(executor.runCount, 0)
        XCTAssertFalse(store.committed.flatMap(\.candidates).contains { $0.kind == .approvalResolved })
    }

    /// Provider 重用同一 proposalID 时，不能覆盖已批准的 immutable
    /// operation，也不能把第二次响应当成新的终端命令执行。
    func testProviderProposalIDReuseFailsClosed() async {
        let proposal = AgentCommandProposal(
            id: "proposal-reused",
            command: "printf first",
            explanation: "第一条命令"
        )
        let reused = AgentCommandProposal(
            id: proposal.id,
            command: "printf different",
            explanation: "不应覆盖"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "先检查", commandProposals: [proposal]),
                AIAssistantResponse(message: "再次返回旧标识", commandProposals: [reused])
            ]
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let context = Self.makeVerifiedLocalTerminalContext()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor,
            targetContextResolver: { runtimeID in
                runtimeID == context.runtimeID ? context : nil
            },
            initialTargetContext: context
        )
        let decision = XCTestExpectation(description: "first approval")
        var proposalID: String?
        let protocolFailure = XCTestExpectation(description: "proposal reuse rejected")
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                guard let value else { return }
                proposalID = value.proposalID
                decision.fulfill()
            }
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .errorRecovery(let text) = $0 { return text.contains("工具调用") }
                    return false
                }) {
                    protocolFailure.fulfill()
                }
            }
        }
        guard case .accepted = await bridge.send(text: "检查") else {
            return XCTFail("首轮工具建议应 accepted")
        }
        await fulfillment(of: [decision], timeout: 5)
        guard let proposalID else { return XCTFail("应产生审批") }
        let resolution = await bridge.resolveToolDecision(proposalID: proposalID, approved: true)
        XCTAssertEqual(resolution, .accepted)
        await fulfillment(of: [protocolFailure], timeout: 5)
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 1, "重用 proposalID 不得再次执行")
        XCTAssertEqual(actor.latestPublishedState?.phase, .failed)
    }

    /// 共享会话中的审批可以从观察窗口提交，但命令只能由持有当前 Runtime 的窗口执行一次。
    func testSharedActorObserverApprovalExecutesOnceThroughOwnerBridge() async {
        let proposal = AgentCommandProposal(
            id: "proposal-shared-window",
            command: "printf shared",
            explanation: "验证跨窗口审批"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "等待另一个窗口批准", commandProposals: [proposal]),
                AIAssistantResponse(message: "跨窗口审批完成", commandProposals: [])
            ]
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let store = InMemoryConversationSessionStore()
        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let context = Self.makeVerifiedLocalTerminalContext()
        let (ownerBridge, observerBridge) = await MainActor.run {
            (
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initialState,
                    provider: provider,
                    providerConfig: config,
                    executionCoordinator: executor,
                    targetContextResolver: { runtimeID in
                        runtimeID == context.runtimeID ? context : nil
                    },
                    initialTargetContext: context
                ),
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initialState,
                    provider: provider,
                    providerConfig: config,
                    executionCoordinator: executor,
                    targetContextResolver: { runtimeID in
                        runtimeID == context.runtimeID ? context : nil
                    },
                    initialTargetContext: context
                )
            )
        }
        let observerDecision = XCTestExpectation(description: "observer receives approval")
        let ownerCompleted = XCTestExpectation(description: "owner resumes after observer approval")
        await MainActor.run {
            observerBridge.onToolDecisionUpdate = { decision in
                if decision?.proposalID == proposal.id {
                    observerDecision.fulfill()
                }
            }
            ownerBridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 { return text == "跨窗口审批完成" }
                    return false
                }) {
                    ownerCompleted.fulfill()
                }
            }
        }

        guard case .accepted = await ownerBridge.send(text: "跨窗口工具审批") else {
            return XCTFail("owner 必须启动运行")
        }
        await fulfillment(of: [observerDecision], timeout: 5)
        let result = await observerBridge.resolveToolDecision(
            proposalID: proposal.id,
            approved: true
        )
        XCTAssertEqual(result, .accepted)
        await fulfillment(of: [ownerCompleted], timeout: 5)

        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        XCTAssertTrue(try store.loadUnsettledOutbox().isEmpty)
    }

    /// Two Inspector windows may display the same pending approval and click at
    /// nearly the same time. Exactly one durable resolution wins; the losing
    /// bridge must refresh its projection without entering sessionBlocked.
    func testConcurrentSharedActorApprovalsDoNotBlockLosingBridge() async {
        let proposal = AgentCommandProposal(
            id: "proposal-concurrent-window",
            command: "printf concurrent",
            explanation: "验证并发审批"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "",
            responses: [
                AIAssistantResponse(message: "等待并发审批", commandProposals: [proposal]),
                AIAssistantResponse(message: "并发审批已处理", commandProposals: [])
            ]
        )
        let store = InMemoryConversationSessionStore()
        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let owner = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: "c-1",
                initialState: initialState,
                provider: provider,
                providerConfig: config
            )
        }
        let ownerCompleted = expectation(description: "owner resumes after losing concurrent approval")
        await MainActor.run {
            owner.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 {
                        return text == "并发审批已处理"
                    }
                    return false
                }) {
                    ownerCompleted.fulfill()
                }
            }
        }
        let observer = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: "c-1",
                initialState: initialState,
                provider: provider,
                providerConfig: config
            )
        }
        let observerDecision = expectation(description: "observer receives concurrent approval")
        await MainActor.run {
            observer.onToolDecisionUpdate = { decision in
                if decision?.proposalID == proposal.id {
                    observerDecision.fulfill()
                }
            }
        }

        guard case .accepted = await owner.send(text: "并发审批") else {
            return XCTFail("owner 必须启动运行")
        }
        await fulfillment(of: [observerDecision], timeout: 5)

        async let ownerResult = owner.resolveToolDecision(
            proposalID: proposal.id,
            approved: false
        )
        async let observerResult = observer.resolveToolDecision(
            proposalID: proposal.id,
            approved: false
        )
        let results = await (ownerResult, observerResult)
        let acceptedCount = [results.0, results.1].filter { $0 == .accepted }.count
        XCTAssertEqual(acceptedCount, 1)
        XCTAssertTrue(
            [results.0, results.1].contains {
                if case .rejected(let reason) = $0 {
                    return reason.contains("另一个窗口")
                }
                return false
            }
        )
        let ownerUsable = await MainActor.run { owner.isSessionUsable }
        let observerUsable = await MainActor.run { observer.isSessionUsable }
        XCTAssertTrue(ownerUsable)
        XCTAssertTrue(observerUsable)
        await fulfillment(of: [ownerCompleted], timeout: 5)
        // Stop here so the fixture cannot leak an active request.
        await owner.stop()
    }

    /// answer-only 即使上游返回命令建议，也只能完成回答，不产生执行 outbox。
    func testAnswerOnlyToolProposalCannotCreateExecutionEffect() async {
        let proposal = AgentCommandProposal(id: "proposal-answer-only", command: "rm -rf /tmp/x", explanation: "不应执行")
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "仅回答",
            response: AIAssistantResponse(message: "仅回答", commandProposals: [proposal])
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let state = Self.makeInitialState(workMode: .answerOnly)
        let store = InMemoryConversationSessionStore()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: state, store: store, sealing: TestConversationSealing()
        )
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: "c-1",
                initialState: state,
                provider: provider,
                providerConfig: ProviderRuntimeConfiguration(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "test-model",
                    apiKey: "test-key"
                ),
                executionCoordinator: executor
            )
        }
        let completed = XCTestExpectation(description: "answer-only complete")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: { if case .finalAnswer(let text) = $0 { return text == "仅回答" }; return false }) {
                    completed.fulfill()
                }
            }
        }
        _ = await bridge.send(text: "只解释")
        await fulfillment(of: [completed], timeout: 5)
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0)
        XCTAssertFalse(store.committed.flatMap(\.outbox).contains { $0.effectID.hasPrefix("executeTool-") })
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
    }

    /// Composer 在发送前切到 answer-only 必须成为本轮 durable 权限快照，
    /// 不能因为 Session 初始值是 agent 就执行上游返回的命令。
    func testComposerAnswerOnlySelectionBlocksToolExecution() async {
        let proposal = AgentCommandProposal(
            id: "proposal-composer-answer-only",
            command: "touch /tmp/should-not-run",
            explanation: "不应执行"
        )
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "只提供解释",
            response: AIAssistantResponse(message: "只提供解释", commandProposals: [proposal])
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor
        )
        await MainActor.run { bridge.setWorkMode(.answerOnly) }

        let completed = XCTestExpectation(description: "composer answer-only completed")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let text) = $0 { return text == "只提供解释" }
                    return false
                }) {
                    completed.fulfill()
                }
            }
        }
        _ = await bridge.send(text: "解释风险")
        await fulfillment(of: [completed], timeout: 5)

        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.workModeSnapshot, .answerOnly)
        XCTAssertFalse(store.committed.flatMap(\.outbox).contains { $0.effectID.hasPrefix("executeTool-") })
    }

    /// 排队时冻结下一轮选择；之后修改 Composer 不得改写已入队上下文。
    func testQueuedInputFreezesWorkModeExecutionChoiceAndTarget() async {
        let provider = FakeStreamingProvider(
            tokens: ["稍后完成"],
            finalMessage: "完成",
            perTokenDelay: 0.5
        )
        let remote = AITerminalContext(
            runtimeID: "term-remote",
            historyScopeID: "scope-remote",
            title: "deploy@prod",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let (bridge, _, _) = await Self.makeBridge(
            provider: provider,
            targetContextResolver: { runtimeID in
                runtimeID == remote.runtimeID ? remote : nil
            }
        )
        _ = await bridge.send(text: "第一轮")
        await MainActor.run {
            bridge.setWorkMode(.planFirst)
            bridge.setExecutionChoice(.backgroundVirtualTerminal)
            XCTAssertTrue(bridge.setTargetRuntimeID(remote.runtimeID))
        }
        let queuedResult = await bridge.queue(text: "第二轮")
        if case .queued = queuedResult {} else { XCTFail("第二轮应进入 durable 队列") }

        await MainActor.run {
            bridge.setWorkMode(.agent)
            bridge.setExecutionChoice(.realTerminal)
            let snapshot = bridge.queuedInputs.first?.contextSnapshot
            XCTAssertEqual(snapshot?.workMode, .plan)
            XCTAssertEqual(snapshot?.terminalMode, TurnExecutionChoice.backgroundVirtualTerminal.rawValue)
            XCTAssertEqual(snapshot?.targetBindingSnapshot.connectionID, remote.runtimeID)
            XCTAssertEqual(snapshot?.targetBindingSnapshot.targetWorkingDirectory, "/srv/app")
        }
        await bridge.stop()
    }

    /// Auto-promotion must use the queued work contract, not the Composer's
    /// later selection. Plan turns never expose terminal.command or stage an
    /// execution effect even when the provider returns a malformed proposal.
    func testQueuedPlanAutoPromotionSendsFrozenZeroToolContract() async {
        let recorder = RequestRecorder()
        let proposal = AgentCommandProposal(
            id: "proposal-queued-plan",
            command: "touch /tmp/queued-plan-must-not-run",
            explanation: "不应执行"
        )
        let provider = FakeStreamingProvider(
            tokens: ["处理中"],
            finalMessage: "完成",
            perTokenDelay: 0.3,
            responses: [
                AIAssistantResponse(message: "第一轮完成", commandProposals: []),
                AIAssistantResponse(message: "计划完成", commandProposals: [proposal])
            ],
            requestRecorder: recorder
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            executionCoordinator: executor
        )

        guard case .accepted = await bridge.send(text: "第一轮") else {
            return XCTFail("第一轮应启动")
        }
        await MainActor.run { bridge.setWorkMode(.planFirst) }
        guard case .queued = await bridge.queue(text: "生成排查计划") else {
            return XCTFail("第二轮应进入队列")
        }
        await MainActor.run { bridge.setWorkMode(.agent) }

        for _ in 0..<100 {
            if await recorder.count() >= 2,
               actor.latestPublishedState?.phase == .completed {
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let promotedRequest = await recorder.lastRequest()
        XCTAssertEqual(promotedRequest?.workMode, .plan)
        XCTAssertEqual(promotedRequest?.allowedToolIDs, [])
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.workModeSnapshot, .plan)
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0)
        XCTAssertFalse(store.committed.flatMap(\.outbox).contains {
            $0.effectID.hasPrefix("executeTool-")
        })
    }

    /// 显式选中的 runtime ID 必须解析为该终端上下文，不能读取当前焦点终端。
    func testFixedTargetResolverFeedsSelectedRuntimeToProvider() async {
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "完成",
            requestRecorder: recorder
        )
        let current = AITerminalContext(
            runtimeID: "term-current", title: "local", currentDirectory: "/tmp", recentTranscript: ""
        )
        let selected = AITerminalContext(
            runtimeID: "term-selected", title: "ops@prod", currentDirectory: "/opt/service", recentTranscript: ""
        )
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            terminalContextProvider: { current },
            targetContextResolver: { runtimeID in
                runtimeID == selected.runtimeID ? selected : nil
            }
        )
        await MainActor.run {
            XCTAssertTrue(bridge.setTargetRuntimeID(selected.runtimeID))
        }
        _ = await bridge.send(text: "检查服务")

        for _ in 0..<50 {
            if await recorder.lastRequest() != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let request = await recorder.lastRequest()
        XCTAssertEqual(request?.context, selected)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.targetBindingSnapshot?.connectionID, selected.runtimeID)
    }

    /// 已显式选择的终端在发送前关闭时必须 fail closed，不能改用当前焦点或空上下文。
    func testSelectedTargetDisappearingBeforeSendRejectsWithoutStartingProvider() async {
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "不应启动",
            requestRecorder: recorder
        )
        let selected = AITerminalContext(
            runtimeID: "term-selected",
            title: "ops@prod",
            currentDirectory: "/opt/service",
            recentTranscript: ""
        )
        let availability = TargetAvailability(context: selected)
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            targetContextResolver: { runtimeID in availability.resolve(runtimeID) }
        )
        await MainActor.run {
            XCTAssertTrue(bridge.setTargetRuntimeID(selected.runtimeID))
            availability.isAvailable = false
            bridge.refreshTargetAvailability()
            XCTAssertEqual(bridge.selectedTargetRuntimeID, selected.runtimeID)
            XCTAssertEqual(bridge.currentTargetIdentity, "ops@prod · 不可用")
        }

        let result = await bridge.send(text: "检查服务")

        XCTAssertEqual(result, .rejected(reason: .targetUnavailable))
        let lastAppliedSequence = actor.currentLastAppliedSequence
        let request = await recorder.lastRequest()
        XCTAssertEqual(lastAppliedSequence, 0)
        XCTAssertNil(request)
    }

    /// A connected SSH pane replaces its temporary pending runtime ID after
    /// establishment. A new turn may safely rebind that stale identity when
    /// the current terminal is still the same device.
    func testPendingTargetRuntimeRebindsToConnectedCurrentTerminalBeforeSend() async {
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "已完成",
            requestRecorder: recorder
        )
        let pending = AITerminalContext(
            runtimeID: "pending-ssh",
            title: "ops@prod",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let connected = AITerminalContext(
            runtimeID: "ssh-live-1",
            title: "ops@prod",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let resolver = RebindingTargetResolver(initial: pending, current: connected)
        let (bridge, actor, _) = await Self.makeBridge(
            provider: provider,
            targetContextResolver: resolver.resolve
        )
        await MainActor.run {
            XCTAssertTrue(bridge.setTargetRuntimeID(pending.runtimeID))
            resolver.promoteCurrentContext()
        }

        let result = await bridge.send(text: "检查服务")

        guard case .accepted = result else {
            return XCTFail("连接后的当前终端应接受新一轮发送")
        }
        for _ in 0..<50 {
            if await recorder.lastRequest() != nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let request = await recorder.lastRequest()
        let reboundRuntimeID = await MainActor.run { bridge.currentTargetRuntimeID }
        XCTAssertEqual(request?.context, connected)
        XCTAssertEqual(reboundRuntimeID, connected.runtimeID)
        XCTAssertEqual(
            actor.latestPublishedState?.activeAttempt?.targetBindingSnapshot?.connectionID,
            connected.runtimeID
        )
    }

    /// 队列冻结目标关闭后不能静默提升；必须标记 needsRebind 并暂停自动推进。
    func testQueuedTargetDisappearingPausesQueueAndRequiresRebind() async {
        let provider = FakeStreamingProvider(
            tokens: ["第一轮"],
            finalMessage: "完成",
            perTokenDelay: 0.08
        )
        let selected = AITerminalContext(
            runtimeID: "term-queued",
            title: "deploy@prod",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let availability = TargetAvailability(context: selected)
        let (bridge, _, _) = await Self.makeBridge(
            provider: provider,
            targetContextResolver: { runtimeID in availability.resolve(runtimeID) }
        )
        _ = await bridge.send(text: "第一轮")
        await MainActor.run {
            XCTAssertTrue(bridge.setTargetRuntimeID(selected.runtimeID))
        }
        if case .queued = await bridge.queue(text: "第二轮") {} else {
            XCTFail("第二轮应进入 durable 队列")
        }
        await MainActor.run { availability.isAvailable = false }

        for _ in 0..<100 {
            let paused = await MainActor.run { bridge.queueAutoAdvancePaused }
            if paused { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let projection = await MainActor.run {
            (bridge.queueAutoAdvancePaused, bridge.queuedInputs.first?.revalidationState, bridge.isIdle)
        }
        XCTAssertTrue(projection.0)
        XCTAssertEqual(projection.1, .needsRebind)
        XCTAssertTrue(projection.2)
    }

    /// runtime ID 可被底层复用，因此队列必须同时冻结连接代次。
    /// 同一 ID 从 generation 1 重连到 2 后，旧消息不能自动提升。
    func testQueuedTargetReconnectPausesQueueAndRequiresRebind() async {
        let provider = FakeStreamingProvider(
            tokens: ["第一轮"],
            finalMessage: "完成",
            perTokenDelay: 0.08
        )
        let selected = AITerminalContext(
            runtimeID: "term-queued-reused",
            connectionGeneration: 1,
            historyScopeID: "scope-reused",
            title: "deploy@prod",
            currentDirectory: "/srv/app",
            recentTranscript: ""
        )
        let availability = TargetAvailability(context: selected)
        let (bridge, _, _) = await Self.makeBridge(
            provider: provider,
            targetContextResolver: { runtimeID in availability.resolve(runtimeID) }
        )
        _ = await bridge.send(text: "第一轮")
        await MainActor.run {
            XCTAssertTrue(bridge.setTargetRuntimeID(selected.runtimeID))
        }
        guard case .queued = await bridge.queue(text: "第二轮") else {
            return XCTFail("第二轮应进入 durable 队列")
        }
        availability.update(AITerminalContext(
            runtimeID: selected.runtimeID,
            connectionGeneration: 2,
            historyScopeID: selected.historyScopeID,
            title: selected.title,
            currentDirectory: selected.currentDirectory,
            recentTranscript: ""
        ))

        for _ in 0..<100 {
            if await MainActor.run(body: { bridge.queueAutoAdvancePaused }) { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let projection = await MainActor.run {
            (
                bridge.queueAutoAdvancePaused,
                bridge.queuedInputs.first?.revalidationState,
                bridge.queuedInputs.first?.contextSnapshot.targetRuntimeGeneration,
                bridge.isIdle
            )
        }
        XCTAssertTrue(projection.0)
        XCTAssertEqual(projection.1, .needsRebind)
        XCTAssertEqual(projection.2, 1)
        XCTAssertTrue(projection.3)
    }

    /// 执行模式 sink 只接收已提交 Turn 的冻结值。运行中修改 Composer 仅影响下一轮。
    func testExecutionModeSinkRemainsFrozenForActiveTurn() async {
        let provider = FakeStreamingProvider(
            tokens: ["慢响应"],
            finalMessage: "完成",
            perTokenDelay: 0.5
        )
        let capture = ExecutionChoiceCapture()
        let (bridge, _, _) = await Self.makeBridge(
            provider: provider,
            executionModeSnapshotHandler: { choice in capture.append(choice) }
        )
        await MainActor.run { bridge.setExecutionChoice(.backgroundVirtualTerminal) }
        _ = await bridge.send(text: "执行检查")
        await MainActor.run {
            XCTAssertEqual(capture.last, .backgroundVirtualTerminal)
            bridge.setExecutionChoice(.realTerminal)
            XCTAssertEqual(capture.last, .backgroundVirtualTerminal)
        }
        await bridge.stop()
    }

    /// Inspector 包装层不能绕过 Bridge 的冻结语义。Composer 在当前
    /// Attempt 运行时修改的是下一轮选择，协调器仍必须读取当前 Turn
    /// 已提交的执行位置。
    func testInspectorRuntimeKeepsCoordinatorModeFrozenWhileComposerChangesNextTurn() async throws {
        let provider = FakeStreamingProvider(
            tokens: ["慢响应"],
            finalMessage: "完成",
            perTokenDelay: 0.5
        )
        let executionModeState = InspectorConversationExecutionModeState(choice: .realTerminal)
        let (bridge, _, _) = await Self.makeBridge(
            provider: provider,
            executionModeSnapshotHandler: { choice in
                executionModeState.applyFrozenTurnChoice(choice)
            }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StacioInspectorExecutionMode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try ConversationRepositoryV2(
            conversationID: "c-1",
            databasePath: directory.appendingPathComponent("conversation.sqlite3").path,
            encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x6B, count: 32))
        )
        let runtime = InspectorConversationRuntime(
            sessionID: "c-1",
            bridge: bridge,
            repository: repository,
            initialExecutionChoice: .realTerminal,
            executionModeState: executionModeState
        )

        runtime.updateExecutionChoice(.backgroundVirtualTerminal)
        XCTAssertEqual(bridge.selectedExecutionChoice, .backgroundVirtualTerminal)
        XCTAssertEqual(executionModeState.choice, .realTerminal)

        _ = await bridge.send(text: "执行检查")
        XCTAssertEqual(executionModeState.choice, .backgroundVirtualTerminal)

        runtime.updateExecutionChoice(.realTerminal)
        XCTAssertEqual(bridge.selectedExecutionChoice, .realTerminal)
        XCTAssertEqual(
            executionModeState.choice,
            .backgroundVirtualTerminal,
            "运行中的协调器不能被下一轮 Composer 选择重定向"
        )
        await bridge.stop()
    }

    /// Bridge 不能因为当前恰好装配了 Native Provider 就覆盖 durable Local Agent 选择。
    /// 用户必须显式提交 Runtime 切换，之后才允许启动 Provider。
    func testRestoredLocalAgentSelectionRequiresExplicitDurableNativeSwitch() async {
        let store = InMemoryConversationSessionStore()
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "完成")
        var initialState = Self.makeInitialState()
        initialState.session.runtimeSelection = AgentRuntimeSelection(
            kind: .localAgent,
            codingPlanConfigurationID: "legacy-plan",
            localAgentConfigurationID: "legacy-codex",
            localAgentExecutionProfileID: "legacy-terminal",
            localAgentExecutionProfileKind: .terminalPassthrough,
            modelID: "legacy-model",
            reasoningEffort: "high",
            workMode: .plan,
            revision: 7
        )
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let bridgeInitialState = initialState
        let config = ProviderRuntimeConfiguration(
            configurationID: "native-provider",
            configurationRevision: 3,
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "native-model",
            apiKey: "test-key"
        )
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: "c-1",
                initialState: bridgeInitialState,
                provider: provider,
                providerConfig: config
            )
        }

        let identity = await MainActor.run { bridge.currentRuntimeIdentity }
        XCTAssertEqual(identity, "Local Agent · legacy-codex")
        let rejectedBeforeSwitch = await bridge.send(text: "不得静默使用 Native")
        XCTAssertEqual(rejectedBeforeSwitch, .rejected(reason: .runtimeUnavailable))
        XCTAssertTrue(store.committed.isEmpty, "拒绝路径不能写 Turn 或启动 Provider")

        let switched = await bridge.selectNativeRuntime()
        XCTAssertTrue(switched)
        let switchedIdentity = await MainActor.run { bridge.currentRuntimeIdentity }
        XCTAssertEqual(switchedIdentity, "Native · native-model")
        guard case .accepted = await bridge.send(text: "显式切换后使用 Native") else {
            return XCTFail("durable Native switch should enable submission")
        }

        let submitted = store.committed
            .flatMap(\.candidates)
            .first(where: { $0.kind == .turnSubmitted })
            .flatMap { EventPayloadCodec.decode(TurnSubmittedPayload.self, from: $0.payload) }
        guard let selection = submitted?.runtimeSelection else {
            XCTFail("turnSubmitted must carry a runtime selection")
            return
        }
        XCTAssertEqual(selection.kind, .nativeAPI)
        XCTAssertEqual(selection.providerConfigurationID, "native-provider")
        XCTAssertEqual(selection.modelID, "native-model")
        XCTAssertNil(selection.codingPlanConfigurationID)
        XCTAssertNil(selection.localAgentConfigurationID)
        XCTAssertNil(selection.localAgentExecutionProfileID)
        XCTAssertEqual(selection.localAgentExecutionProfileKind, .none)
        XCTAssertEqual(selection.reasoningEffort, "medium")
        XCTAssertEqual(selection.revision, 9, "next-turn reasoning snapshot advances selection revision")
    }

    /// API Key 型 Coding Plan 复用 Native transport，但 durable identity 和
    /// 认证绑定必须始终保持为 Coding Plan，且能通过统一 RuntimeRouter 校验。
    func testNativeCodingPlanQueueSnapshotPreservesIdentityAndAuthenticationEvidence() async {
        let store = InMemoryConversationSessionStore()
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "完成")
        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let config = ProviderRuntimeConfiguration(
            configurationID: "coding-plan-config",
            configurationRevision: 4,
            runtimeConfigurationKind: .codingPlan,
            baseURL: URL(string: "https://api.kimi.com/coding/v1")!,
            model: "user-selected-model",
            apiKey: "test-key"
        )
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: "c-1",
                initialState: initialState,
                provider: provider,
                providerConfig: config
            )
        }

        let result = await bridge.queue(text: "排队执行")
        if case .queued = result {} else { XCTFail("Coding Plan input should be queued") }

        await MainActor.run {
            XCTAssertEqual(bridge.currentRuntimeIdentity, "Coding Plan · user-selected-model")
            guard let snapshot = bridge.queuedInputs.first?.contextSnapshot else {
                XCTFail("Queue must persist a context snapshot")
                return
            }
            XCTAssertNil(snapshot.providerConfigurationID)
            XCTAssertEqual(snapshot.codingPlanConfigurationID, "coding-plan-config")
            XCTAssertNil(snapshot.runtimeSelectionSnapshot.providerConfigurationID)
            XCTAssertEqual(
                snapshot.runtimeSelectionSnapshot.codingPlanConfigurationID,
                "coding-plan-config"
            )
            XCTAssertEqual(
                snapshot.runtimeAuthenticationSnapshot.configurationID,
                "coding-plan-config"
            )
            XCTAssertFalse(snapshot.runtimeAuthenticationSnapshot.generationIDsByRole.isEmpty)

            var session = initialState.session
            session.runtimeSelection = snapshot.runtimeSelectionSnapshot
            XCTAssertEqual(
                RuntimeRouter.route(
                    session: session,
                    authentication: snapshot.runtimeAuthenticationSnapshot
                ),
                .success(.codingPlan(codingPlanConfigurationID: "coding-plan-config"))
            )
        }
    }

    func testNativeSendFailsClosedWhenExternalProviderHasNoCredential() async {
        let store = InMemoryConversationSessionStore()
        let recorder = RequestRecorder()
        let provider = FakeStreamingProvider(
            tokens: [],
            finalMessage: "不应发送",
            requestRecorder: recorder
        )
        let initialState = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initialState,
            store: store,
            sealing: TestConversationSealing()
        )
        let config = ProviderRuntimeConfiguration(
            configurationID: "external-provider",
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: nil
        )
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: "c-1",
                initialState: initialState,
                provider: provider,
                providerConfig: config
            )
        }

        let result = await bridge.send(text: "不得发出")
        XCTAssertEqual(result, .rejected(reason: .providerUnavailable))
        let request = await recorder.lastRequest()
        XCTAssertNil(request, "认证快照未验证时不得调用上游")
        XCTAssertEqual(actor.currentLastAppliedSequence, 0, "拒绝路由不得写入 Turn")
    }

    /// V1 只写 UTF-8 文本 payload；升级后 replay 必须继续使用 envelope 身份并恢复文本。
    func testReducerReplaysLegacyPlainTextTurnPayload() {
        let state = Self.makeInitialState()
        let (tentative, effects) = ConversationReducer.reduce(
            state: state,
            draft: Self.makeDraft(
                kind: .turnSubmitted,
                sequence: 1,
                expected: 0,
                payload: Data("旧会话问题".utf8)
            )
        )
        XCTAssertTrue(tentative.isValid)
        XCTAssertEqual(tentative.state.activeTurn?.id, "t-1")
        XCTAssertEqual(tentative.state.activeAttempt?.id, "a-1")
        XCTAssertEqual(tentative.state.activeTurn?.userRequest, "旧会话问题")
        XCTAssertEqual(effects, [.requestAdmission(sessionID: "c-1", turnID: "t-1", attemptID: "a-1")])
    }

    /// 空白消息不可发送（isIdle 保持，Actor 无推进）。
    func testBridgeRejectsEmptyMessage() async {
        let provider = FakeStreamingProvider(tokens: ["x"], finalMessage: "x")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider)

        _ = await bridge.send(text: "   ")
        // 给一点时间确保没有异步推进
        try? await Task.sleep(nanoseconds: 100_000_000)
        let lastApplied = actor.currentLastAppliedSequence
        XCTAssertEqual(lastApplied, 0, "空白消息不应推进 Actor")
        let isIdle = bridge.isIdle
        XCTAssertTrue(isIdle, "空白发送后应仍 Idle")
    }

    func testAskEveryTurnRejectsNativeSendUntilExecutionChoiceIsSelected() async {
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "should not run")
        let (bridge, actor, store) = await Self.makeBridge(
            provider: provider,
            initialExecutionChoice: .ask
        )

        let result = await bridge.send(text: "needs a terminal choice")
        XCTAssertEqual(result, .rejected(reason: .executionChoiceRequired))
        XCTAssertNil(actor.latestPublishedState?.activeAttempt)
        XCTAssertTrue(store.committed.isEmpty)

        await MainActor.run { bridge.setExecutionChoice(.backgroundVirtualTerminal) }
        let accepted = await bridge.send(text: "now selected")
        if case .accepted = accepted {
            // expected
        } else {
            XCTFail("an explicit per-turn terminal choice should permit send")
        }
        await bridge.stop()
    }

    /// Repository replay must own the session before any first-frame UI action can append events
    /// or replace the durable next-turn selection.
    func testRestorePendingBlocksEarlyRuntimeAndDurableMutations() async {
        let provider = FakeStreamingProvider(tokens: ["不应启动"], finalMessage: "不应启动")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider, restorePending: true)

        let initialMode = bridge.selectedWorkMode
        let sendResult = await bridge.send(text: "恢复期间发送")
        let queueResult = await bridge.queue(text: "恢复期间排队")
        await MainActor.run {
            bridge.setWorkMode(.planFirst)
            bridge.updateDraft("恢复期间输入")
        }
        try? await Task.sleep(nanoseconds: 350_000_000)

        let projection = await MainActor.run {
            (bridge.selectedWorkMode, bridge.allowsAlternateRuntimeSelection)
        }
        let lastAppliedSequence = actor.currentLastAppliedSequence

        XCTAssertEqual(sendResult, .rejected(reason: .alreadyRunning))
        XCTAssertEqual(queueResult, .rejected(reason: .alreadyRunning))
        XCTAssertEqual(projection.0, initialMode)
        XCTAssertFalse(projection.1)
        XCTAssertEqual(lastAppliedSequence, 0)
    }

    // MARK: - Timeline VC diffable 应用

    /// apply(entries:) 增量更新条目数。
    @MainActor
    func testTimelineVCAppliesEntries() {
        let vc = ConversationTimelineViewController()
        vc.view.layoutSubtreeIfNeeded()
        vc.apply(entries: [
            .userMessage("你好"),
            .finalAnswer("回复")
        ])
        XCTAssertEqual(vc.itemCount, 2, "Timeline 应包含 2 条目")
        vc.apply(entries: [.userMessage("新问题"), .finalAnswer("答案"), .errorRecovery("失败")])
        XCTAssertEqual(vc.itemCount, 3, "Timeline 增量更新后应包含 3 条目")
    }

    // MARK: - 辅助

    private static func makeVerifiedLocalTerminalContext() -> AITerminalContext {
        AITerminalContext(
            runtimeID: "local",
            connectionGeneration: 0,
            isConnected: true,
            historyScopeID: "scope-local",
            title: "Local Terminal",
            currentDirectory: "~",
            recentTranscript: ""
        )
    }

    private static func makeInitialState(workMode: WorkMode = .agent) -> ConversationSessionState {
        let target = TargetBinding(
            id: "tb-1", revision: 1, digest: "d1", connectionID: "local",
            connectionKind: "local", remoteIdentity: "user@host", hostKeyFingerprint: nil,
            host: "localhost", user: "user", port: 0, targetWorkingDirectory: "~"
        )
        let session = ConversationSession(
            id: "c-1", title: "测试", createdAt: Date(), updatedAt: Date(),
            targetBinding: target,
            runtimeSelection: AgentRuntimeSelection(kind: .nativeAPI, workMode: workMode)
        )
        return ConversationSessionState(session: session, lastAppliedSequence: 0)
    }

    private static func makeDraft(
        kind: ConversationEventKind, sequence: Int, expected: Int, payload: Data = Data()
    ) -> EventDraft {
        let envelope = ConversationEventEnvelope(
            eventID: "ev-\(sequence)", conversationID: "c-1", scope: .attempt,
            turnID: "t-1", attemptID: "a-1", candidateSequence: sequence,
            source: "test", timestamp: Date(), kind: kind,
            writeClass: .durable, payloadHash: "h-\(sequence)", payload: payload
        )
        return EventDraft(envelope: envelope, expectedLastSequence: expected)
    }

    private static func apply(
        state: ConversationSessionState, kind: ConversationEventKind,
        sequence: Int, expected: Int, payload: Data = Data()
    ) -> TentativeState {
        ConversationReducer.reduce(state: state, draft: makeDraft(kind: kind, sequence: sequence, expected: expected, payload: payload)).0
    }

    private static func makeBridge(
        provider: AIAssistantStreamingProviding,
        executionCoordinator: AgentCommandStreamingExecuting? = nil,
        terminalContextProvider: @escaping () -> AITerminalContext? = { nil },
        targetContextResolver: ((String?) -> AITerminalContext?)? = nil,
        executionModeSnapshotHandler: ((TurnExecutionChoice) -> Void)? = nil,
        terminalAutomationPolicyProvider: @escaping (String?) -> SessionAutomationPolicy? = { _ in
            SessionAutomationPolicy(
                environment: "development",
                aiExecutionPolicy: "requireEveryCommand"
            )
        },
        settingsProvider: @escaping () -> AppSettings = { AppSettings() },
        initialTargetContext: AITerminalContext? = nil,
        initialExecutionChoice: TurnExecutionChoice = .realTerminal,
        restorePending: Bool = false,
        runtimeSettingsProvider: @escaping () throws -> AssistantRuntimeSettingsSnapshot = {
            try AssistantRuntimeSettingsSnapshot.resolve(from: nil)
        }
    ) async -> (bridge: SessionRuntimeBridge, actor: ConversationSessionActor, store: InMemoryConversationSessionStore) {
        let store = InMemoryConversationSessionStore()
        let sealing = TestConversationSealing()
        let initialState = makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1", initialState: initialState, store: store, sealing: sealing
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model", apiKey: "test-key"
        )
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor, sessionID: "c-1", initialState: initialState,
                provider: provider, providerConfig: config,
                executionCoordinator: executionCoordinator,
                terminalContextProvider: terminalContextProvider,
                targetContextResolver: targetContextResolver,
                executionModeSnapshotHandler: executionModeSnapshotHandler,
                runtimeSettingsProvider: runtimeSettingsProvider,
                settingsProvider: settingsProvider,
                terminalAutomationPolicyProvider: terminalAutomationPolicyProvider,
                initialTargetContext: initialTargetContext,
                initialExecutionChoice: initialExecutionChoice,
                restorePending: restorePending
            )
        }
        return (bridge, actor, store)
    }
}

// MARK: - Fake Streaming Provider

final class FakeStreamingProvider: AIAssistantStreamingProviding {
    private let tokens: [String]
    private let finalMessage: String
    private let error: Error?
    private let perTokenDelay: TimeInterval
    private let responseOverride: AIAssistantResponse?
    private let responses: [AIAssistantResponse]?
    private let requestRecorder: RequestRecorder?
    private var responseIndex = 0
    private let responseLock = NSLock()

    init(
        tokens: [String],
        finalMessage: String,
        error: Error? = nil,
        perTokenDelay: TimeInterval = 0,
        response: AIAssistantResponse? = nil,
        responses: [AIAssistantResponse]? = nil,
        requestRecorder: RequestRecorder? = nil
    ) {
        self.tokens = tokens
        self.finalMessage = finalMessage
        self.error = error
        self.perTokenDelay = perTokenDelay
        self.responseOverride = response
        self.responses = responses
        self.requestRecorder = requestRecorder
    }

    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        await requestRecorder?.record(request)
        if let error { throw error }
        for token in tokens {
            if perTokenDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(perTokenDelay * 1_000_000_000))
            }
            try Task.checkCancellation()
            onPartial(token)
        }
        if let responses, responses.isEmpty == false {
            let index = responseLock.withLock {
                let index = min(responseIndex, max(0, responses.count - 1))
                responseIndex += 1
                return index
            }
            return responses[index]
        }
        return responseOverride ?? AIAssistantResponse(message: finalMessage, proposedCommand: nil)
    }
}

private final class CancellationIgnoringStreamingProvider: AIAssistantStreamingProviding {
    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        try? await Task.sleep(nanoseconds: 250_000_000)
        onPartial("迟到增量")
        return AIAssistantResponse(message: "迟到完成", proposedCommand: nil)
    }
}

private final class CancellationObservingStreamingProvider: AIAssistantStreamingProviding, @unchecked Sendable {
    let started = XCTestExpectation(description: "provider started")
    let cancelled = XCTestExpectation(description: "provider task cancelled")

    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        started.fulfill()
        return try await withTaskCancellationHandler {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return AIAssistantResponse(message: "不应完成", proposedCommand: nil)
        } onCancel: {
            self.cancelled.fulfill()
        }
    }
}

actor RequestRecorder {
    private var requests: [AIAssistantRequest] = []

    func record(_ request: AIAssistantRequest) {
        requests.append(request)
    }

    func lastRequest() -> AIAssistantRequest? {
        requests.last
    }

    func count() -> Int {
        requests.count
    }
}

final class TargetAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var context: AITerminalContext
    private var available = true

    init(context: AITerminalContext) {
        self.context = context
    }

    var isAvailable: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return available
        }
        set {
            lock.lock()
            available = newValue
            lock.unlock()
        }
    }

    func resolve(_ runtimeID: String?) -> AITerminalContext? {
        lock.lock()
        defer { lock.unlock() }
        guard available, runtimeID == context.runtimeID else { return nil }
        return context
    }

    func update(_ context: AITerminalContext) {
        lock.lock()
        self.context = context
        lock.unlock()
    }
}

final class RebindingTargetResolver: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: AITerminalContext
    private let current: AITerminalContext
    private var usesConnectedContext = false

    init(initial: AITerminalContext, current: AITerminalContext) {
        self.initial = initial
        self.current = current
    }

    func promoteCurrentContext() {
        lock.lock()
        usesConnectedContext = true
        lock.unlock()
    }

    func resolve(_ runtimeID: String?) -> AITerminalContext? {
        lock.lock()
        defer { lock.unlock() }
        if runtimeID == nil {
            return usesConnectedContext ? current : initial
        }
        if usesConnectedContext {
            return runtimeID == current.runtimeID ? current : nil
        }
        return runtimeID == initial.runtimeID ? initial : nil
    }
}

final class ExecutionChoiceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TurnExecutionChoice] = []

    func append(_ choice: TurnExecutionChoice) {
        lock.lock()
        values.append(choice)
        lock.unlock()
    }

    var last: TurnExecutionChoice? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}

@MainActor
final class FakeV2CommandExecutor: AgentCommandStreamingExecuting, AgentTaskControlling {
    private(set) var runCount = 0
    private(set) var requests: [AgentBridgeRequest] = []

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        runCount += 1
        requests.append(request)
        let command: String?
        if case .runCommand(let payload) = request.action {
            command = payload.command
        } else {
            command = nil
        }
        let queued = AgentTraceEvent(
            requestID: request.id,
            state: .queued,
            message: "已排队",
            redactedCommand: command
        )
        let completed = AgentTraceEvent(
            requestID: request.id,
            state: .completed,
            message: "执行完成",
            redactedCommand: command,
            metadata: ["terminalOutputSummary": "ok"]
        )
        emit(queued)
        emit(completed)
        return [queued, completed]
    }

    func pauseTask(requestID: String) -> AgentTraceEvent? { nil }
    func cancelTask(requestID: String) -> AgentTraceEvent? {
        AgentTraceEvent(
            requestID: requestID,
            state: .cancelled,
            message: "已取消",
            redactedCommand: nil
        )
    }
    func takeOverTask(requestID: String) -> AgentTraceEvent? { nil }
}

@MainActor
final class TraceProjectingV2CommandExecutor: AgentCommandStreamingExecuting, AgentTaskControlling {
    private let executionMode: String?
    private let terminalOutput: String
    private let terminalHistoryOutput: String?

    init(
        executionMode: String?,
        terminalOutput: String,
        terminalHistoryOutput: String? = nil
    ) {
        self.executionMode = executionMode
        self.terminalOutput = terminalOutput
        self.terminalHistoryOutput = terminalHistoryOutput
    }

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        var metadata = [
            "sourceRuntimeID": "local",
            "terminalOutputSummary": terminalOutput,
            "completionReason": "agentCompletionMarker"
        ]
        if let executionMode {
            metadata["executionMode"] = executionMode
        }
        if let terminalHistoryOutput {
            metadata["terminalHistoryOutput"] = terminalHistoryOutput
        }
        let completed = AgentTraceEvent(
            requestID: request.id,
            state: .completed,
            message: "命令已完成：\(terminalOutput)",
            redactedCommand: {
                if case .runCommand(let payload) = request.action { return payload.command }
                return nil
            }(),
            metadata: metadata
        )
        emit(completed)
        return [completed]
    }

    func pauseTask(requestID: String) -> AgentTraceEvent? { nil }
    func cancelTask(requestID: String) -> AgentTraceEvent? { nil }
    func takeOverTask(requestID: String) -> AgentTraceEvent? { nil }
}

@MainActor
final class UnconfirmedCancellationV2CommandExecutor: AgentCommandStreamingExecuting, AgentTaskControlling {
    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        let running = AgentTraceEvent(
            requestID: request.id,
            state: .running,
            message: "命令仍在运行",
            redactedCommand: "tail -f service.log",
            metadata: [
                "executionMode": "visibleTerminal",
                "sourceRuntimeID": "local"
            ]
        )
        emit(running)
        return [running]
    }

    func pauseTask(requestID: String) -> AgentTraceEvent? { nil }
    func cancelTask(requestID: String) -> AgentTraceEvent? { nil }
    func takeOverTask(requestID: String) -> AgentTraceEvent? { nil }
}

@MainActor
final class TerminalThenThrowingV2CommandExecutor: AgentCommandStreamingExecuting {
    private(set) var runCount = 0

    func runCommand(_ request: AgentBridgeRequest) throws -> [AgentTraceEvent] {
        try runCommand(request, emit: { _ in })
    }

    func runCommand(
        _ request: AgentBridgeRequest,
        emit: @escaping (AgentTraceEvent) -> Void
    ) throws -> [AgentTraceEvent] {
        runCount += 1
        emit(AgentTraceEvent(
            requestID: request.id,
            state: .cancelled,
            message: "用户已拒绝终端命令",
            redactedCommand: "printf should-not-run"
        ))
        throw AgentExecutionError.denied("用户已拒绝终端命令")
    }
}
