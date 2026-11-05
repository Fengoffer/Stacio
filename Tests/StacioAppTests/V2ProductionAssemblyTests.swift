import AppKit
import XCTest
import Foundation
import SQLite3
import StacioAgentBridge
@testable import StacioApp

// MARK: - P0 生产装配测试（P0-10）

/// 生产级集成测试：真实密封 + 临时 SQLite Repository + 多 Turn + 重启恢复 + 无 Provider + 存储失败 + 非流式 + Stop 迟到回调。
/// 所有测试用真实 ConversationEncryption（CryptoKit AES-GCM + Keychain 主密钥或测试主密钥）+ 真实 ConversationRepositoryV2（Rust SQLite）。
@MainActor
final class V2ProductionAssemblyTests: XCTestCase {
    func testProviderAuthenticationIdentityNeverDependsOnAPIKeyMaterial() {
        let endpoint = URL(string: "https://api.example.com/v1")!
        let first = ProviderRuntimeConfiguration(
            configurationID: "provider-1",
            baseURL: endpoint,
            model: "model-1",
            apiKey: "secret-key-alpha",
            credentialGenerationID: "generation-7"
        )
        let replacementValueForSameGeneration = ProviderRuntimeConfiguration(
            configurationID: "provider-1",
            baseURL: endpoint,
            model: "model-1",
            apiKey: "secret-key-beta",
            credentialGenerationID: "generation-7"
        )
        let rotatedGeneration = ProviderRuntimeConfiguration(
            configurationID: "provider-1",
            baseURL: endpoint,
            model: "model-1",
            apiKey: "secret-key-alpha",
            credentialGenerationID: "generation-8"
        )

        let firstDigest = SessionRuntimeBridge.providerAuthenticationDigest(first)
        XCTAssertEqual(
            firstDigest,
            SessionRuntimeBridge.providerAuthenticationDigest(replacementValueForSameGeneration),
            "Authentication identity must use the non-secret generation, not API key bytes"
        )
        XCTAssertNotEqual(
            firstDigest,
            SessionRuntimeBridge.providerAuthenticationDigest(rotatedGeneration)
        )
        XCTAssertFalse(first.description.contains("secret-key-alpha"))
        XCTAssertTrue(first.description.contains("apiKey: [redacted]"))
    }


    func testNewSessionStateCarriesQueueAutoAdvanceDefault() {
        let paused = ConversationV2StorageFactory.makeInitialSessionState(
            sessionID: "queue-default-paused",
            queueAutoAdvanceEnabled: false
        )
        let enabled = ConversationV2StorageFactory.makeInitialSessionState(
            sessionID: "queue-default-enabled",
            queueAutoAdvanceEnabled: true
        )
        XCTAssertEqual(paused.session.queueAutoAdvancePaused, true)
        XCTAssertEqual(enabled.session.queueAutoAdvancePaused, false)
    }

    // MARK: - P0-1：真实 ConversationEncryption + 临时 SQLite Repository 集成测试

    /// 真实加密 + 真实 Rust Repository：提交事件后能加载并解密 replay。
    func testRealEncryptionAndRepositoryRoundTrip() throws {
        let conversationID = "conv-encryption-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let masterKey = Data((0..<32).map { UInt8((($0 * 7 + 1) % 251) + 1) })
        let encryption = ConversationEncryption(masterKeyData: masterKey)
        let repo = try ConversationRepositoryV2(conversationID: conversationID, databasePath: dbPath, encryption: encryption)

        // 构造一个 turnSubmitted 事件并提交
        let envelope = ConversationEventEnvelope(
            eventID: "ev-1", conversationID: conversationID, scope: .attempt,
            turnID: "turn-1", attemptID: "attempt-1", candidateSequence: 1,
            source: "test", timestamp: Date(), kind: .turnSubmitted,
            writeClass: .durable, payloadHash: "h-1", payload: Data("你好".utf8)
        )
        let outbox = ConversationEffectOutboxFactory.make(
            commands: [], sessionID: conversationID, turnID: "turn-1", attemptID: "attempt-1"
        )
        let outcome = try repo.commit(expectedLastSequence: 0, candidates: [envelope], projections: [:], outbox: outbox)
        if case .committed(let seq) = outcome {
            XCTAssertEqual(seq, 1)
        } else {
            XCTFail("提交应成功")
        }

        // 加载并解密 replay
        let loaded = try repo.loadEvents()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].kind, .turnSubmitted)
        XCTAssertEqual(loaded[0].payload, Data("你好".utf8), "解密后 payload 必须与原始一致")
        // turnID/attemptID 不在 Rust 明文列（仅存密文 payload）；replay 时由 reducer 从 turnSubmitted 重建。
    }

    func testRepositoryRejectsTamperedCreatedAtIndex() throws {
        let conversationID = "conv-created-at-index-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x7A, count: 32))
        )
        let envelope = ConversationEventEnvelope(
            eventID: "event-created-at",
            conversationID: conversationID,
            scope: .turn,
            turnID: "turn-1",
            attemptID: "attempt-1",
            candidateSequence: 1,
            source: "test",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .turnSubmitted,
            writeClass: .durable,
            payloadHash: "hash-created-at",
            payload: Data("问题".utf8)
        )
        _ = try repository.commit(
            expectedLastSequence: 0,
            candidates: [envelope],
            projections: [:],
            outbox: []
        )

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(dbPath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil),
            SQLITE_OK
        )
        defer { sqlite3_close(database) }
        let tamperSQL = "UPDATE conversation_v2_event SET created_at = 'tampered' WHERE conversation_id = '\(conversationID)' AND sequence = 1"
        XCTAssertEqual(sqlite3_exec(database, tamperSQL, nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try repository.loadEvents()) { error in
            guard case ConversationRepositoryV2Error.corruptedEvent(let sequence, _) = error else {
                return XCTFail("索引篡改必须在 Swift 回放边界失败关闭：\(error)")
            }
            XCTAssertEqual(sequence, 1)
        }
    }

    func testDurableOutboxClaimSettleAndReopenRoundTrip() throws {
        let conversationID = "conv-outbox-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x31, count: 32))
        var repository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let envelope = ConversationEventEnvelope(
            eventID: "ev-1", conversationID: conversationID, scope: .attempt,
            turnID: "turn-1", attemptID: "attempt-1", candidateSequence: 1,
            source: "test", timestamp: Date(), kind: .runtimeStartRequested,
            writeClass: .durable, payloadHash: "h-1", payload: Data()
        )
        let expectedCommand = EffectCommand.startRuntime(attemptID: "attempt-1")
        let outbox = ConversationEffectOutboxFactory.make(
            commands: [expectedCommand],
            sessionID: conversationID,
            turnID: "turn-1",
            attemptID: "attempt-1",
            authorityLeaseID: "lease-1",
            capabilityGeneration: 41
        )
        _ = try repository?.commit(
            expectedLastSequence: 0,
            candidates: [envelope],
            projections: [:],
            outbox: outbox
        )

        let pending = try XCTUnwrap(repository).loadUnsettledOutbox()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].command, expectedCommand)
        XCTAssertEqual(pending[0].capabilityGeneration, 41)
        XCTAssertEqual(pending[0].state, .pending)
        let claimed = try XCTUnwrap(try repository?.claimOutboxEffect(
            effectID: pending[0].effectID,
            dispatchToken: "dispatch-1",
            dispatchedAt: "2026-08-10T00:00:00Z"
        ))
        XCTAssertEqual(claimed.state, .dispatching)
        XCTAssertNil(try repository?.claimOutboxEffect(
            effectID: pending[0].effectID,
            dispatchToken: "dispatch-2",
            dispatchedAt: "2026-08-10T00:00:01Z"
        ))
        XCTAssertFalse(try XCTUnwrap(repository).settleOutbox(
            itemID: claimed.itemID,
            dispatchToken: "wrong-token",
            outcome: .acknowledged,
            settledAt: "2026-08-10T00:00:02Z"
        ))
        XCTAssertTrue(try XCTUnwrap(repository).settleOutbox(
            itemID: claimed.itemID,
            dispatchToken: "dispatch-1",
            outcome: .acknowledged,
            settledAt: "2026-08-10T00:00:02Z"
        ))
        repository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        XCTAssertTrue(try reopened.loadUnsettledOutbox().isEmpty)
    }

    func testDurableSchedulerSerializesProviderStartsAcrossTwoBridges() async throws {
        let schedulerRepository = try ConversationRepositoryV2(
            conversationID: "scheduler-owner-\(UUID().uuidString)",
            databasePath: tempDBPath(),
            encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x53, count: 32))
        )
        let scheduler = ProductionAgentExecutionScheduler(
            store: schedulerRepository,
            capacity: 1
        )
        let settings = try Self.runtimeSettings(maxParallelAttempts: 1)
        let firstProvider = DelayedCountingStreamingProvider(delayNanoseconds: 700_000_000)
        let secondProvider = DelayedCountingStreamingProvider(delayNanoseconds: 1_000_000)
        let firstStarted = expectation(description: "first provider started")
        let secondStarted = expectation(description: "second provider started after release")
        firstProvider.onInvocation = { _ in firstStarted.fulfill() }
        secondProvider.onInvocation = { _ in secondStarted.fulfill() }

        let (firstBridge, _, _) = await Self.makeBridge(
            provider: firstProvider,
            conversationID: "capacity-session-1",
            admissionCoordinator: scheduler,
            runtimeSettingsSnapshot: settings
        )
        let (secondBridge, secondActor, _) = await Self.makeBridge(
            provider: secondProvider,
            conversationID: "capacity-session-2",
            admissionCoordinator: scheduler,
            runtimeSettingsSnapshot: settings
        )

        guard case .accepted = await firstBridge.send(text: "first") else {
            return XCTFail("first turn should be admitted")
        }
        await fulfillment(of: [firstStarted], timeout: 2)

        guard case .accepted = await secondBridge.send(text: "second") else {
            return XCTFail("second turn should be durably queued")
        }
        XCTAssertEqual(secondActor.latestPublishedState?.phase, .waitingForCapacity)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(
            secondProvider.invocationCount,
            0,
            "capacity=1 must keep the second Provider behind the first lease"
        )

        await fulfillment(of: [secondStarted], timeout: 3)
        XCTAssertEqual(secondProvider.invocationCount, 1)
        let state = try schedulerRepository.loadAdmissionState()
        XCTAssertLessThanOrEqual(state.activeLeases.filter(\.occupiesCapacity).count, 1)
    }

    func testDispatchingOutboxRequiresReconciliationAfterReopen() throws {
        let conversationID = "conv-outbox-unknown-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x42, count: 32))
        var repository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let envelope = ConversationEventEnvelope(
            eventID: "ev-1", conversationID: conversationID, scope: .attempt,
            turnID: "turn-1", attemptID: "attempt-1", candidateSequence: 1,
            source: "test", timestamp: Date(), kind: .approvalResolved,
            writeClass: .durable, payloadHash: "h-1", payload: Data()
        )
        let command = EffectCommand.executeTool(attemptID: "attempt-1", proposalID: "proposal-1")
        _ = try repository?.commit(
            expectedLastSequence: 0,
            candidates: [envelope],
            projections: [:],
            outbox: ConversationEffectOutboxFactory.make(
                commands: [command],
                sessionID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1"
            )
        )
        let effectID = ConversationEffectOutboxFactory.stableEffectID(for: command)
        let claimed = try XCTUnwrap(try repository?.claimOutboxEffect(
            effectID: effectID,
            dispatchToken: "dispatch-1",
            dispatchedAt: "2026-08-10T00:00:00Z"
        ))
        repository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        XCTAssertNil(try reopened.claimOutboxEffect(
            effectID: effectID,
            dispatchToken: "dispatch-2",
            dispatchedAt: "2026-08-10T00:00:01Z"
        ))
        XCTAssertTrue(try reopened.requireOutboxReconciliation(
            itemID: claimed.itemID,
            reason: "external result unknown"
        ))
        let unresolved = try reopened.loadUnsettledOutbox()
        XCTAssertEqual(unresolved.first?.state, .reconciliationRequired)
        XCTAssertEqual(unresolved.first?.reconciliationReason, "external result unknown")
    }

    func testReadOnlyHistoryRestoreDoesNotDispatchProviderOrMutateDurableState() async throws {
        let conversationID = "conv-read-only-\(UUID().uuidString)"
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: tempDBPath(),
            encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x61, count: 32))
        )
        let specs: [(ConversationEventKind, Data, ConversationEventScope, String)] = [
            (.turnSubmitted, Data("只读恢复中的任务".utf8), .turn, "user"),
            (.admissionRequested, Data(), .attempt, "runtime"),
            (.admissionGranted, Data(), .attempt, "runtime"),
            (.runtimeStarted, Data(), .attempt, "runtime")
        ]
        let envelopes = specs.enumerated().map { index, spec in
            seededDraft(
                conversationID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1",
                sequence: index + 1,
                kind: spec.0,
                payload: spec.1,
                scope: spec.2,
                source: spec.3
            ).envelope
        }
        let pendingRuntime = EffectCommand.startRuntime(attemptID: "attempt-1")
        _ = try repository.commit(
            expectedLastSequence: 0,
            candidates: envelopes,
            projections: [:],
            outbox: ConversationEffectOutboxFactory.make(
                commands: [pendingRuntime],
                sessionID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1"
            )
        )
        let before = try repository.loadUnsettledOutbox()
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "不得调用")
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let recorder = await MainActor.run { TimelineEntryRecorder() }
        let bridge = await MainActor.run {
            let bridge = SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                provider: provider,
                providerConfig: config,
                accessMode: .readOnlyHistory
            )
            bridge.onTimelineUpdate = { [weak recorder] entries in
                recorder?.entries = entries
            }
            return bridge
        }

        let restored = await bridge.restoreFromRepository(repository)
        XCTAssertTrue(restored)

        let after = try repository.loadUnsettledOutbox()
        XCTAssertEqual(after, before, "只读历史不得 claim、settle 或隔离 outbox")
        XCTAssertEqual(provider.invocationCount, 0, "只读历史不得启动 Provider")
        XCTAssertEqual(actor.currentLastAppliedSequence, 0, "只读 replay 不得推进共享写 Actor")
        let sendResult = await bridge.send(text: "不能发送")
        XCTAssertEqual(sendResult, .rejected(reason: .readOnly))
        let bridgeState = await MainActor.run {
            (bridge.isReadOnlyHistory, bridge.requiresHostClosureSettlement, recorder.entries)
        }
        XCTAssertTrue(bridgeState.0)
        XCTAssertFalse(bridgeState.1, "只读历史不得参与宿主关闭结算")
        XCTAssertTrue(bridgeState.2.contains { entry in
            if case .userMessage("只读恢复中的任务") = entry { return true }
            return false
        })
        XCTAssertTrue(bridgeState.2.contains { entry in
            if case .planProgress("未完成的 V2 任务 · 执行中") = entry { return true }
            return false
        })
    }

    func testReadOnlyHistoryRendersEmptyStateWithoutWriting() async throws {
        let conversationID = "conv-read-only-empty-\(UUID().uuidString)"
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: tempDBPath(),
            encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x62, count: 32))
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: TestConversationSealing()
        )
        let recorder = await MainActor.run { TimelineEntryRecorder() }
        let bridge = await MainActor.run {
            let bridge = SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                restorePending: true,
                accessMode: .readOnlyHistory
            )
            bridge.onTimelineUpdate = { [weak recorder] entries in recorder?.entries = entries }
            return bridge
        }

        let restored = await bridge.restoreFromRepository(repository)

        XCTAssertFalse(restored)
        XCTAssertEqual(actor.currentLastAppliedSequence, 0)
        XCTAssertTrue(try repository.loadEvents().isEmpty)
        let entries = await MainActor.run { recorder.entries }
        XCTAssertTrue(entries.contains { entry in
            if case .planProgress("暂无 V2 会话记录") = entry { return true }
            return false
        })
    }

    func testDrainFenceRejectsNewTurnsAndPreventsQueuedInputAutoPromotion() async throws {
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 100_000_000)
        let (bridge, _, _) = await Self.makeBridge(provider: provider)

        let first = await bridge.send(text: "排空前已获准的任务")
        guard case .accepted = first else {
            return XCTFail("首个任务应在 drain fence 前启动：\(first)")
        }
        let queued = await bridge.queue(text: "不得在 draining 中自动提升")
        XCTAssertEqual(queued, .queued(position: 1))

        await MainActor.run {
            bridge.suspendNewSubmissions()
        }
        let rejected = await bridge.send(text: "draining 后的新任务")
        XCTAssertEqual(rejected, .rejected(reason: .draining))

        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(provider.invocationCount, 1, "排空前任务可结算，但队列不得启动第二次 Provider")
        let projection = await MainActor.run {
            (bridge.queuedCount, bridge.isIdle, bridge.acceptsNewTurns)
        }
        XCTAssertEqual(projection.0, 1)
        XCTAssertTrue(projection.1)
        XCTAssertFalse(projection.2)
    }

    func testRestoreRejectsFinalizeOutboxThatContradictsTerminalEvent() async throws {
        let conversationID = "conv-finalize-mismatch-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x43, count: 32))
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let termination = AttemptTerminationPayload(outcome: .completed, reasonCode: .completed)
        let specs: [(ConversationEventKind, Data, ConversationEventScope, String)] = [
            (.turnSubmitted, Data("问题".utf8), .turn, "user"),
            (.admissionRequested, Data(), .attempt, "runtime"),
            (.admissionGranted, Data(), .attempt, "runtime"),
            (.runtimeStarted, Data(), .attempt, "runtime"),
            (.finalAnswerCompleted, Data("答案".utf8), .attempt, "provider"),
            (.attemptCompleted, EventPayloadCodec.encode(termination) ?? Data(), .attempt, "runtime")
        ]
        let envelopes = specs.enumerated().map { index, spec in
            seededDraft(
                conversationID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1",
                sequence: index + 1,
                kind: spec.0,
                payload: spec.1,
                scope: spec.2,
                source: spec.3
            ).envelope
        }
        let contradictory = EffectCommand.finalizeAttempt(
            attemptID: "attempt-1",
            outcome: .failed,
            reasonCode: .providerRequestFailed
        )
        _ = try repository.commit(
            expectedLastSequence: 0,
            candidates: envelopes,
            projections: [:],
            outbox: ConversationEffectOutboxFactory.make(
                commands: [contradictory],
                sessionID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1"
            )
        )

        let (bridge, _, _) = await Self.makeBridge(
            provider: nil,
            store: repository,
            conversationID: conversationID,
            skipProvider: true
        )
        let restored = await bridge.restoreFromRepository(repository)
        XCTAssertFalse(restored)
        let unsettled = try repository.loadUnsettledOutbox()
        XCTAssertEqual(unsettled.count, 1)
        XCTAssertEqual(unsettled[0].state, .reconciliationRequired)
        XCTAssertEqual(
            unsettled[0].reconciliationReason,
            "attempt terminal evidence does not match finalize command"
        )
    }

    func testRestoreDoesNotRedispatchPendingRuntimeLaunchAfterRelaunch() async throws {
        let conversationID = "conv-runtime-multiplicity-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x44, count: 32))
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let selection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: config.effectiveConfigurationID,
            modelID: config.model
        )
        let configurationDigest = SessionRuntimeBridge.providerConfigurationDigest(
            selection: selection,
            configuration: config
        )
        let authenticationDigest = SessionRuntimeBridge.providerAuthenticationDigest(
            config,
            selection: selection
        )
        let authentication = RuntimeAuthenticationSnapshot(
            mode: .stacioCredentialBindings,
            configurationID: config.effectiveConfigurationID,
            configurationRevision: config.configurationRevision,
            normalizedModelOrigin: WebsiteActionResolver.normalizedOrigin(url: config.baseURL),
            verificationFingerprint: configurationDigest,
            generationIDsByRole: ["apiKey": config.credentialGenerationID!],
            createdAt: Date(timeIntervalSince1970: 1),
            digest: authenticationDigest
        )
        let submitted = TurnSubmittedPayload(
            text: "恢复运行",
            runtimeSelection: selection,
            targetBinding: initial.session.targetBinding,
            terminalMode: TurnExecutionChoice.realTerminal.rawValue,
            ordinal: 1,
            runtimeAuthenticationSnapshot: authentication,
            configurationRevisionDigest: configurationDigest
        )
        let specs: [(ConversationEventKind, Data, ConversationEventScope, String)] = [
            (.turnSubmitted, EventPayloadCodec.encode(submitted) ?? Data(), .turn, "user"),
            (.admissionRequested, Data(), .attempt, "runtime"),
            (.admissionGranted, Data(), .attempt, "runtime"),
            (.runtimeStarted, Data(), .attempt, "runtime")
        ]
        let envelopes = specs.enumerated().map { index, spec in
            seededDraft(
                conversationID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1",
                sequence: index + 1,
                kind: spec.0,
                payload: spec.1,
                scope: spec.2,
                source: spec.3
            ).envelope
        }
        _ = try repository.commit(
            expectedLastSequence: 0,
            candidates: envelopes,
            projections: [:],
            outbox: ConversationEffectOutboxFactory.make(
                commands: [.startRuntime(attemptID: "attempt-1")],
                sessionID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1"
            )
        )

        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "不得启动")
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                provider: provider,
                providerConfig: config
            )
        }
        let restored = await bridge.restoreFromRepository(repository)

        XCTAssertFalse(restored)
        XCTAssertEqual(provider.invocationCount, 0)
        let unsettled = try repository.loadUnsettledOutbox()
        XCTAssertEqual(unsettled.count, 1)
        XCTAssertTrue(unsettled.allSatisfy { $0.state == .reconciliationRequired })
        XCTAssertTrue(unsettled.allSatisfy {
            $0.reconciliationReason == "runtime launch may have crossed the process crash boundary"
        })
    }

    func testRestoreNeverRedispatchesPendingLocalAgentRuntimeInput() async throws {
        try await assertLocalAgentRuntimeRecoveryDoesNotRedispatch(claimBeforeRestart: false)
    }

    func testRestoreNeverRedispatchesClaimedLocalAgentRuntimeInput() async throws {
        try await assertLocalAgentRuntimeRecoveryDoesNotRedispatch(claimBeforeRestart: true)
    }

    func testRestoreDoesNotRedispatchPendingApprovedToolAfterRelaunch() async throws {
        let conversationID = "conv-tool-pending-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x53, count: 32))
        var repository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        try seedApprovedToolState(
            repository: try XCTUnwrap(repository),
            conversationID: conversationID,
            proposalID: "proposal-pending"
        )
        repository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: reopened,
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "工具恢复完成")
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let bridge = await MainActor.run {
            let targetContext = Self.recoveryToolTargetContext
            return SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                provider: provider,
                providerConfig: ProviderRuntimeConfiguration(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "test-model",
                    apiKey: "test-key"
                ),
                executionCoordinator: executor,
                targetContextResolver: { runtimeID in
                    runtimeID == targetContext.runtimeID ? targetContext : nil
                }
            )
        }
        let restored = await bridge.restoreFromRepository(reopened)
        XCTAssertFalse(restored, "重启后的 pending tool 必须进入对账，不得自动执行")
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0)
        XCTAssertEqual(provider.invocationCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .interruptedByRelaunch)
        let unresolved = try XCTUnwrap(try reopened.loadUnsettledOutbox().first)
        XCTAssertEqual(unresolved.state, .reconciliationRequired)
        XCTAssertEqual(
            unresolved.reconciliationReason,
            "tool dispatch has no durable terminal evidence"
        )
    }

    func testCancelledRestoreDoesNotRunProviderOrToolAndDoesNotReportStorageCorruption() async throws {
        let conversationID = "conv-cancelled-restore-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x65, count: 32))
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        try seedApprovedToolState(
            repository: repository,
            conversationID: conversationID,
            proposalID: "proposal-cancelled-restore"
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "不得调用")
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                provider: provider,
                providerConfig: ProviderRuntimeConfiguration(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "test-model",
                    apiKey: "test-key"
                ),
                executionCoordinator: executor,
                restorePending: true
            )
        }
        let restoreTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return await bridge.restoreFromRepository(repository)
        }
        restoreTask.cancel()

        let restored = await restoreTask.value

        XCTAssertFalse(restored)
        XCTAssertEqual(provider.invocationCount, 0)
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCount, 0)
        let storageError = await MainActor.run { bridge.storageError }
        XCTAssertNil(storageError)
        let isRestoring = await MainActor.run { bridge.isRestoring }
        XCTAssertFalse(isRestoring)
    }

    /// App 重启会切断审批所依赖的进程与终端 lease。旧建议保留为
    /// 可核对、可复制的只读记录，但不能继续审批或执行。
    func testRestoreInvalidatesPendingApprovalWithoutExecutingAndAllowsNewTurn() async throws {
        let conversationID = "conv-approval-relaunch-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x72, count: 32))
        var repository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let proposalID = "proposal-relaunch-approval"
        try seedAwaitingApprovalState(
            repository: try XCTUnwrap(repository),
            conversationID: conversationID,
            proposalID: proposalID
        )
        repository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: reopened,
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "新一轮完成")
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                provider: provider,
                providerConfig: ProviderRuntimeConfiguration(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "test-model",
                    apiKey: "test-key"
                ),
                executionCoordinator: executor
            )
        }
        let decision = XCTestExpectation(description: "pending approval restored")
        var restoredPresentation: PendingToolDecisionPresentation?
        await MainActor.run {
            bridge.onToolDecisionUpdate = { value in
                guard value?.proposalID == proposalID else { return }
                restoredPresentation = value
                decision.fulfill()
            }
        }

        let restored = await bridge.restoreFromRepository(reopened)
        XCTAssertTrue(restored)
        await fulfillment(of: [decision], timeout: 5)
        XCTAssertEqual(restoredPresentation?.command, "pwd")
        XCTAssertFalse(try XCTUnwrap(restoredPresentation).isActionable)
        XCTAssertTrue(restoredPresentation?.statusMessage?.contains("重启后该审批已失效") == true)
        XCTAssertEqual(actor.latestPublishedState?.phase, .interruptedByRelaunch)
        let runCountBeforeApproval = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCountBeforeApproval, 0)
        XCTAssertTrue(
            try reopened.loadEvents().contains(where: { $0.kind == .attemptInterruptedByRelaunch }),
            "重启必须持久化切断旧审批的执行边界"
        )

        let resolution = await bridge.resolveToolDecision(proposalID: proposalID, approved: true)
        XCTAssertEqual(
            resolution,
            .rejected(reason: "App 重启后该审批已失效，请基于当前连接重新生成建议")
        )
        XCTAssertFalse(try reopened.loadEvents().contains(where: { $0.kind == .approvalResolved }))
        XCTAssertEqual(provider.invocationCount, 0)
        let runCountAfterRejectedApproval = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCountAfterRejectedApproval, 0)

        let completed = XCTestExpectation(description: "new turn completes after stale approval")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let value) = $0 { return value == "新一轮完成" }
                    return false
                }) {
                    completed.fulfill()
                }
            }
        }
        let sendResult = await bridge.send(text: "请基于当前连接重新检查")
        guard case .accepted = sendResult else {
            return XCTFail("A stale approval must not block a fresh turn: \(sendResult)")
        }
        await fulfillment(of: [completed], timeout: 5)
        let runCountAfterNewTurn = await MainActor.run { executor.runCount }
        XCTAssertEqual(runCountAfterNewTurn, 0)
        XCTAssertEqual(actor.latestPublishedState?.phase, .completed)
        XCTAssertTrue(try reopened.loadUnsettledOutbox().isEmpty)
    }

    func testRestoreNeverReplaysDispatchingToolWithoutTerminalEvidence() async throws {
        let conversationID = "conv-tool-unknown-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x64, count: 32))
        var repository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let effectID = try seedApprovedToolState(
            repository: try XCTUnwrap(repository),
            conversationID: conversationID,
            proposalID: "proposal-unknown"
        )
        _ = try XCTUnwrap(repository).claimOutboxEffect(
            effectID: effectID,
            dispatchToken: "dispatch-before-crash",
            dispatchedAt: "2026-08-10T00:00:00Z"
        )
        repository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: reopened,
            sealing: TestConversationSealing()
        )
        let executor = await MainActor.run { FakeV2CommandExecutor() }
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                provider: CountingStreamingProvider(message: "不得调用"),
                providerConfig: ProviderRuntimeConfiguration(
                    baseURL: URL(string: "https://api.example.com/v1")!,
                    model: "test-model",
                    apiKey: "test-key"
                ),
                executionCoordinator: executor
            )
        }

        let restored = await bridge.restoreFromRepository(reopened)
        let runCount = await MainActor.run { executor.runCount }
        XCTAssertFalse(restored)
        XCTAssertEqual(runCount, 0)
        let unresolved = try reopened.loadUnsettledOutbox()
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved[0].state, .reconciliationRequired)
        XCTAssertTrue(unresolved[0].reconciliationReason?.contains("no durable terminal evidence") == true)
    }

    func testRestorePreservesCancelledToolOutboxOutcome() async throws {
        let conversationID = "conv-tool-cancelled-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x73, count: 32))
        var repository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let effectID = try seedApprovedToolState(
            repository: try XCTUnwrap(repository),
            conversationID: conversationID,
            proposalID: "proposal-cancelled"
        )
        let dispatchToken = "dispatch-before-cancel-crash"
        let claimed = try XCTUnwrap(try repository?.claimOutboxEffect(
            effectID: effectID,
            dispatchToken: dispatchToken,
            dispatchedAt: "2026-08-11T00:00:00Z"
        ))
        var snapshot = Self.makeInitialState(conversationID: conversationID)
        for envelope in try XCTUnwrap(repository).loadEvents() {
            let draft = EventDraft(
                envelope: envelope,
                expectedLastSequence: snapshot.lastAppliedSequence
            )
            let tentative = ConversationReducer.reduce(state: snapshot, draft: draft).0
            guard tentative.isValid else {
                return XCTFail("种子事件必须能重建 approved tool 状态")
            }
            snapshot = tentative.state
        }
        var actor: ConversationSessionActor? = ConversationSessionActor(
            sessionID: conversationID,
            initialState: snapshot,
            store: try XCTUnwrap(repository),
            sealing: TestConversationSealing()
        )
        let requestID = "request-cancelled-before-settle"
        let started = RecoveryToolExecutionEventPayload(
            proposalID: "proposal-cancelled",
            requestID: requestID,
            state: AgentTraceState.running.rawValue,
            summary: "工具执行已开始"
        )
        let cancelled = RecoveryToolExecutionEventPayload(
            proposalID: "proposal-cancelled",
            requestID: requestID,
            state: AgentTraceState.cancelled.rawValue,
            summary: "用户已停止"
        )
        let resolution = ToolProposalResolutionPayload(
            proposalID: "proposal-cancelled",
            result: nil,
            error: "用户已停止"
        )
        let specs: [(ConversationEventKind, Data)] = [
            (.toolStarted, try JSONEncoder().encode(started)),
            (.toolCompleted, try JSONEncoder().encode(cancelled)),
            (.toolProposalResolved, try JSONEncoder().encode(resolution))
        ]
        let drafts = specs.enumerated().map { index, spec in
            seededDraft(
                conversationID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1",
                sequence: snapshot.lastAppliedSequence + index + 1,
                kind: spec.0,
                payload: spec.1,
                scope: .attempt,
                source: "agent-execution"
            )
        }
        guard case .committed = try XCTUnwrap(actor).submitSync(drafts) else {
            return XCTFail("取消终态必须先于模拟崩溃持久化")
        }
        actor = nil
        repository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let restoredActor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: reopened,
            sealing: TestConversationSealing()
        )
        let bridge = SessionRuntimeBridge(
            actor: restoredActor,
            sessionID: conversationID,
            initialState: initial,
            provider: CountingStreamingProvider(message: "不得调用"),
            providerConfig: ProviderRuntimeConfiguration(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "test-model",
                apiKey: "test-key"
            )
        )

        let restored = await bridge.restoreFromRepository(reopened)
        XCTAssertTrue(restored)
        XCTAssertTrue(try reopened.loadUnsettledOutbox().isEmpty)
        XCTAssertTrue(try reopened.settleOutbox(
            itemID: claimed.itemID,
            dispatchToken: dispatchToken,
            outcome: .cancelled,
            settledAt: "2026-08-11T00:00:02Z"
        ))
        XCTAssertFalse(try reopened.settleOutbox(
            itemID: claimed.itemID,
            dispatchToken: dispatchToken,
            outcome: .failed,
            settledAt: "2026-08-11T00:00:03Z"
        ))
    }

    /// 同一数据库使用错误主密钥时必须认证失败，不能把历史当成空会话继续覆盖。
    func testRepositoryWrongMasterKeyFailsClosed() throws {
        let conversationID = "conv-wrong-key-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let firstKey = Data(repeating: 0x11, count: 32)
        let secondKey = Data(repeating: 0x22, count: 32)
        var writer: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: ConversationEncryption(masterKeyData: firstKey)
        )
        let envelope = ConversationEventEnvelope(
            eventID: "ev-1", conversationID: conversationID, scope: .turn,
            turnID: "turn-1", attemptID: "attempt-1", candidateSequence: 1,
            source: "test", timestamp: Date(), kind: .turnSubmitted,
            writeClass: .durable, payloadHash: "h-1", payload: Data("secret".utf8)
        )
        _ = try writer?.commit(
            expectedLastSequence: 0,
            candidates: [envelope],
            projections: [:],
            outbox: []
        )
        writer = nil

        let reader = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: ConversationEncryption(masterKeyData: secondKey)
        )
        XCTAssertThrowsError(try reader.loadEvents()) { error in
            XCTAssertEqual(error as? ConversationEncryptionError, .authenticationFailed)
        }
    }

    /// 统一密封合同：ConversationEncryptionSealingAdapter.verifyRoundTrip 接收明文，内部 seal→open 往返。
    func testSealingAdapterVerifyRoundTripWithPlaintext() throws {
        let masterKey = Data((0..<32).map { UInt8((($0 * 3 + 1) % 251) + 1) })
        let encryption = ConversationEncryption(masterKeyData: masterKey)
        let adapter = ConversationEncryptionSealingAdapter(encryption: encryption, conversationID: "conv-seal")
        let payload = Data("测试明文 payload".utf8)
        let aad = "stacio.v2|conversationEvent|ev-1|1|schema-1"
        XCTAssertTrue(adapter.verifyRoundTrip(payload: payload, aad: aad), "明文 payload 往返验证必须通过")
    }

    /// fail-closed 后备密封器：verifyRoundTrip 永远返回 false（不通过验证 → Actor 不提交）。
    func testFallbackSealingFailsClosed() {
        let fallback = InProcessFallbackSealing()
        XCTAssertFalse(fallback.verifyRoundTrip(payload: Data("x".utf8), aad: "aad"), "fail-closed 后备密封器必须返回 false")
    }

    // MARK: - P0-3：提交失败不启动 Provider

    /// Actor submitSync 返回结构化结果；sealing 失败时返回 rejected。
    func testSubmitSyncReturnsStructuredResult() {
        let store = InMemoryConversationSessionStore()
        let sealing = TestConversationSealing()
        sealing.shouldVerify = false // 模拟 sealing 失败
        let state = Self.makeInitialState()
        let actor = ConversationSessionActor(sessionID: "c-1", initialState: state, store: store, sealing: sealing)
        let draft = EventDraft(
            envelope: ConversationEventEnvelope(
                eventID: "ev-1", conversationID: "c-1", scope: .attempt,
                turnID: "t-1", attemptID: "a-1", candidateSequence: 1,
                source: "test", timestamp: Date(), kind: .turnSubmitted,
                writeClass: .durable, payloadHash: "h-1", payload: Data("问".utf8)
            ),
            expectedLastSequence: 0
        )
        let outcome = actor.submitSync([draft])
        if case .rejected(let reason) = outcome {
            XCTAssertEqual(reason, .sealingFailed, "sealing 失败应返回 sealingFailed")
        } else {
            XCTFail("sealing 失败时应返回 rejected")
        }
    }

    /// 启动事务存储失败时 Provider 不得收到任何网络请求。
    func testStorageFailureDoesNotStartProvider() async {
        let provider = CountingStreamingProvider(message: "不应调用")
        let store = ScriptedConversationSessionStore(outcomes: [
            .storageFailure(reason: "disk full")
        ])
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)

        let result = await bridge.send(text: "问题")

        XCTAssertEqual(result, .rejected(reason: .storageUnavailable))
        XCTAssertEqual(provider.invocationCount, 0, "durable 启动事务失败后不得启动 Provider")
        XCTAssertEqual(store.commitCount, 1)
    }

    /// 并发冲突同样必须在 Provider 边界前失败。
    func testStorageConflictDoesNotStartProvider() async {
        let provider = CountingStreamingProvider(message: "不应调用")
        let store = ScriptedConversationSessionStore(outcomes: [
            .conflict(expected: 0, actual: 1)
        ])
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)

        let result = await bridge.send(text: "问题")

        XCTAssertEqual(result, .rejected(reason: .storageUnavailable))
        XCTAssertEqual(provider.invocationCount, 0, "sequence 冲突时不得启动 Provider")
    }

    /// Provider 已完成但终态事务失败时，会话必须进入 fail-closed，不能继续发送。
    func testTerminalCommitFailureBlocksFurtherTurns() async {
        let provider = CountingStreamingProvider(message: "回答")
        let store = ScriptedConversationSessionStore(
            outcomes: [],
            failingEventKind: .attemptCompleted
        )
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)
        let blocked = XCTestExpectation(description: "terminal persistence failure blocks session")
        await MainActor.run {
            bridge.onRuntimeUnavailable = { message in
                if message.contains("完成回答") {
                    blocked.fulfill()
                }
            }
        }

        let first = await bridge.send(text: "问题")
        guard case .accepted = first else {
            return XCTFail("首轮应在启动事务提交后 accepted")
        }
        await fulfillment(of: [blocked], timeout: 5)

        let second = await bridge.send(text: "第二轮")
        XCTAssertEqual(second, .rejected(reason: .storageUnavailable))
        XCTAssertEqual(provider.invocationCount, 1)
    }

    // MARK: - Durable Local Agent terminal passthrough

    func testLocalAgentRuntimeSelectionCommitFailureKeepsNativeSelection() async {
        let store = ScriptedConversationSessionStore(outcomes: [
            .storageFailure(reason: "selection write failed")
        ])
        let (bridge, actor, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )

        let selected = await bridge.selectLocalAgentRuntime(
            configuration: Self.makeLocalAgentConfiguration()
        )

        XCTAssertFalse(selected)
        XCTAssertEqual(actor.latestPublishedState?.session.runtimeSelection.kind, .nativeAPI)
        let currentKind = await MainActor.run { bridge.currentRuntimeSelection.kind }
        XCTAssertEqual(currentKind, .nativeAPI)
    }

    func testSelectingLocalAgentRuntimeDoesNotLaunchOrCreateTurn() async {
        let store = InMemoryConversationSessionStore()
        let (bridge, _, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )

        let selected = await bridge.selectLocalAgentRuntime(
            configuration: Self.makeLocalAgentConfiguration()
        )

        XCTAssertTrue(selected)
        XCTAssertEqual(store.committed.count, 1)
        XCTAssertEqual(store.committed[0].candidates.map(\.kind), [.runtimeSelectionChanged])
        XCTAssertFalse(store.committed.flatMap(\.candidates).contains { $0.kind == .turnSubmitted })
        XCTAssertTrue(try! store.loadUnsettledOutbox().isEmpty)
    }

    func testStructuredLocalAgentTurnPersistsManagedProfileKind() async {
        let store = InMemoryConversationSessionStore()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let configuration = Self.makeLocalAgentConfiguration(structuredProtocol: .rpc)
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)

        let result = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: { XCTFail("managed Runtime must not write to the PTY"); return .notRunning }
        )

        guard case .accepted = result else {
            return XCTFail("A durable managed Local Agent turn should be accepted")
        }
        let submitted = store.committed
            .flatMap(\.candidates)
            .first(where: { $0.kind == .turnSubmitted })
            .flatMap { EventPayloadCodec.decode(TurnSubmittedPayload.self, from: $0.payload) }
        XCTAssertEqual(submitted?.terminalMode, LocalAgentExecutionProfileKind.managed.rawValue)
        XCTAssertEqual(
            actor.latestPublishedState?.activeAttempt?.terminalModeSnapshot,
            LocalAgentExecutionProfileKind.managed.rawValue
        )
        guard let workspaceSnapshot = actor.latestPublishedState?.activeAttempt?.agentProcessWorkingDirectorySnapshot,
              let workspacePath = workspaceSnapshot.localPathReference
        else {
            return XCTFail("Structured Local Agent must persist a session workspace")
        }
        XCTAssertEqual(workspaceSnapshot.mode, .managedWorkspace)
        XCTAssertTrue(workspacePath.hasSuffix("/AgentWorkspace/sessions/c-1"))
        XCTAssertEqual(workspaceSnapshot.allowedFilesystemScope, [workspacePath])
    }

    func testLocalAgentTurnCommitFailureNeverWritesPTY() async {
        let store = ScriptedConversationSessionStore(outcomes: [
            .committed(lastSequence: 1),
            .storageFailure(reason: "turn write failed")
        ])
        let (bridge, _, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let configuration = Self.makeLocalAgentConfiguration()
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)
        var deliveryCount = 0

        let result = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: {
                deliveryCount += 1
                return .accepted
            }
        )

        XCTAssertEqual(result, .rejected(reason: .storageUnavailable))
        XCTAssertEqual(deliveryCount, 0, "PTY write must remain behind the durable Turn boundary")
    }

    func testLocalAgentSuccessfulDeliveryHasHonestTerminalOutcomeWithoutCanonicalAnswer() async {
        let store = InMemoryConversationSessionStore()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let configuration = Self.makeLocalAgentConfiguration()
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)
        var deliveredTexts: [String] = []

        let result = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: {
                deliveredTexts.append("inspect nginx")
                return .accepted
            }
        )

        guard case .accepted = result else {
            return XCTFail("durable PTY delivery should be accepted")
        }
        XCTAssertEqual(deliveredTexts, ["inspect nginx"])
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .passthroughInputDelivered)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.outcome, .passthroughInputDelivered)
        XCTAssertNil(actor.latestPublishedState?.activeAttempt?.partialAnswer)
        XCTAssertEqual(
            actor.latestPublishedState?.activeTurn?.finalAnswerState,
            CanonicalFinalAnswerState.none
        )
        XCTAssertNil(actor.latestPublishedState?.activeTurn?.canonicalFinalAnswerAttemptID)
        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        XCTAssertTrue(kinds.contains(.localAgentInputDelivered))
        XCTAssertFalse(kinds.contains(.finalAnswerCompleted))
        XCTAssertFalse(kinds.contains(.attemptCompleted))
    }

    func testLocalAgentDurableTurnClaimFailureIsReportedAcceptedWithoutPTYWrite() async {
        let store = InMemoryConversationSessionStore()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let configuration = Self.makeLocalAgentConfiguration()
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)
        bridge.updateDraft("inspect nginx")
        store.rejectNextOutboxClaim = true
        var deliveryCount = 0

        let result = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: {
                deliveryCount += 1
                return .accepted
            }
        )

        guard case .accepted = result else {
            return XCTFail("Turn 已落盘后不能向 Composer 报告为未发送")
        }
        XCTAssertEqual(deliveryCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.activeTurn?.userRequest, "inspect nginx")
        XCTAssertEqual(actor.latestPublishedState?.session.draft ?? "", "")
    }

    func testAskEveryTurnPersistsSelectedLocalDirectoryInTurnSnapshot() async throws {
        let store = InMemoryConversationSessionStore()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacio-turn-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = Self.makeLocalAgentConfiguration(
            workingDirectoryMode: .askEveryTurn
        )
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)

        let result = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            workingDirectoryReference: directory.path,
            deliver: { .accepted }
        )

        guard case .accepted = result else {
            return XCTFail("A verified per-turn directory should be accepted")
        }
        let snapshot = try XCTUnwrap(
            actor.latestPublishedState?.activeAttempt?.agentProcessWorkingDirectorySnapshot
        )
        XCTAssertEqual(snapshot.mode, .askEveryTurn)
        XCTAssertEqual(snapshot.localPathReference, directory.path)
        XCTAssertEqual(snapshot.allowedFilesystemScope, [directory.path])
        XCTAssertFalse(snapshot.digest?.isEmpty ?? true)
    }

    func testLocalAgentPTYWriteFailureCreatesDurableFailedAttempt() async {
        let store = InMemoryConversationSessionStore()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let configuration = Self.makeLocalAgentConfiguration()
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)

        let result = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: { .notRunning }
        )

        XCTAssertEqual(result, .rejected(reason: .runtimeUnavailable))
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .failed)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.outcome, .failed)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.error, AttemptReasonCode.runtimeStartFailed.rawValue)
        let kinds = store.committed.flatMap(\.candidates).map(\.kind)
        XCTAssertTrue(kinds.contains(.attemptFailed))
        XCTAssertFalse(kinds.contains(.localAgentInputDelivered))
    }

    func testLocalAgentDeterministicPTYFailureRestoresDurableDraft() async {
        let store = InMemoryConversationSessionStore()
        let (bridge, actor, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let configuration = Self.makeLocalAgentConfiguration()
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)
        bridge.updateDraft("inspect nginx")

        let result = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: { .notRunning }
        )
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(result, .rejected(reason: .runtimeUnavailable))
        XCTAssertEqual(actor.latestPublishedState?.session.draft, "inspect nginx")
    }

    func testLocalAgentPostWriteCommitFailureReturnsDeliveredAndBlocksDuplicateSend() async {
        let store = ScriptedConversationSessionStore(
            outcomes: [],
            failingEventKind: .localAgentInputDelivered
        )
        let (bridge, _, _) = await Self.makeBridge(
            provider: nil,
            store: store,
            skipProvider: true
        )
        let configuration = Self.makeLocalAgentConfiguration()
        let selected = await bridge.selectLocalAgentRuntime(configuration: configuration)
        XCTAssertTrue(selected)
        var deliveryCount = 0

        let first = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: {
                deliveryCount += 1
                return .accepted
            }
        )
        let second = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: {
                deliveryCount += 1
                return .accepted
            }
        )

        guard case .accepted = first else {
            return XCTFail("externally visible delivery must not be reported as unsent")
        }
        XCTAssertEqual(second, .rejected(reason: .storageUnavailable))
        XCTAssertEqual(deliveryCount, 1, "an uncertain external write must never invite a duplicate")
    }

    // MARK: - P0-4：多 Turn 连续发送

    /// 连续发送两轮：第一轮完成后第二轮能创建新 Turn，历史投影到模型上下文。
    func testTwoConsecutiveTurns() async {
        let provider = FakeStreamingProvider(tokens: ["答"], finalMessage: "答案1")
        let (bridge, _, _) = await Self.makeBridge(provider: provider)

        let firstDone = XCTestExpectation(description: "first turn done")
        let secondDone = XCTestExpectation(description: "second turn done")
        var answers: [String] = []

        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                for entry in entries {
                    if case .finalAnswer(let t) = entry, t.contains("答案") {
                        if answers.contains(t) == false {
                            answers.append(t)
                            if answers.count == 1 { firstDone.fulfill() }
                            if answers.count == 2 { secondDone.fulfill() }
                        }
                    }
                }
            }
        }
        let r1 = await bridge.send(text: "问题1")
        if case .accepted(let turnID) = r1 {
            XCTAssertTrue(turnID.contains("turn-1"), "第一轮 turnID 应含 turn-1")
        } else {
            XCTFail("第一轮应 accepted")
        }

        await fulfillment(of: [firstDone], timeout: 5)

        // 第二轮（provider 需要返回不同消息）
        let provider2 = FakeStreamingProvider(tokens: ["答"], finalMessage: "答案2")
        bridge.setProvider(provider2, config: ProviderRuntimeConfiguration(baseURL: URL(string: "https://api.example.com/v1")!, model: "test-model", apiKey: "test-key"))
        let r2 = await bridge.send(text: "问题2")
        if case .accepted(let turnID) = r2 {
            XCTAssertTrue(turnID.contains("turn-2"), "第二轮 turnID 应含 turn-2")
        } else {
            XCTFail("第二轮应 accepted")
        }

        await fulfillment(of: [secondDone], timeout: 5)
        XCTAssertEqual(answers.count, 2, "应有两轮回答")
    }

    // MARK: - P0-5：重启恢复

    /// 发送一轮后关闭 Repository，重新打开并 replay 恢复状态，继续发送第二轮。
    func testRestartRecoveryRestoresState() async throws {
        let conversationID = "conv-restart-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let masterKey = Data((0..<32).map { UInt8((($0 * 11 + 3) % 251) + 1) })
        let encryption = ConversationEncryption(masterKeyData: masterKey)

        // 第一次打开：发送一轮
        var repo1: ConversationRepositoryV2? = try ConversationRepositoryV2(conversationID: conversationID, databasePath: dbPath, encryption: encryption)
        let provider = FakeStreamingProvider(tokens: ["恢"], finalMessage: "恢复测试")
        var bridge1: SessionRuntimeBridge? = await Self.makeBridge(
            provider: provider,
            store: try XCTUnwrap(repo1),
            conversationID: conversationID
        ).bridge

        let firstDone = XCTestExpectation(description: "first turn before restart")
        await MainActor.run {
            bridge1?.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let answer) = $0 { return answer == "恢复测试" }
                    return false
                }) {
                    firstDone.fulfill()
                }
            }
        }
        _ = await bridge1?.send(text: "重启前的问题")
        await fulfillment(of: [firstDone], timeout: 5)

        bridge1 = nil
        repo1 = nil

        // 关闭并重新打开 Repository
        // repo1 deinit 会 close handle；重新打开同一 dbPath
        let repo2 = try ConversationRepositoryV2(conversationID: conversationID, databasePath: dbPath, encryption: encryption)

        // 验证能加载事件
        let loaded = try repo2.loadEvents()
        XCTAssertGreaterThan(loaded.count, 0, "重启后应能加载持久化事件")

        // restoreFromRepository 恢复 bridge 状态
        let (bridge2, _, _) = await Self.makeBridge(provider: provider, store: repo2, conversationID: conversationID, skipProvider: true)
        let restored = await bridge2.restoreFromRepository(repo2)
        XCTAssertTrue(restored, "重启恢复应成功")

        // 恢复后继续发送第二轮
        let secondDone = XCTestExpectation(description: "second turn after restart")
        bridge2.setProvider(provider, config: ProviderRuntimeConfiguration(baseURL: URL(string: "https://api.example.com/v1")!, model: "test-model", apiKey: "test-key"))
        await MainActor.run {
            bridge2.onTimelineUpdate = { entries in
                let userMessages = entries.filter {
                    if case .userMessage = $0 { return true }
                    return false
                }
                if userMessages.count >= 2 {
                    secondDone.fulfill()
                }
            }
        }
        let r = await bridge2.send(text: "重启后的问题")
        if case .rejected(let reason) = r {
            XCTFail("恢复后第二轮不应被拒绝：\(reason)")
        }
        await fulfillment(of: [secondDone], timeout: 5)
    }

    func testRestoreResolvesPersistedProviderIDWithoutFallingBackToGlobalDefault() async throws {
        let conversationID = "conv-provider-route-\(UUID().uuidString)"
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x37, count: 32))
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: tempDBPath(),
            encryption: encryption
        )
        var persisted = Self.makeInitialState(conversationID: conversationID)
        persisted.session.runtimeSelection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: "provider-b",
            modelID: "model-b"
        )
        let payload = try JSONEncoder().encode(
            ConversationSessionCreatedPayload(session: persisted.session)
        )
        let created = ConversationEventEnvelope(
            eventID: "event-provider-route",
            conversationID: conversationID,
            scope: .session,
            turnID: nil,
            attemptID: nil,
            candidateSequence: 1,
            source: "test",
            timestamp: Date(),
            kind: .sessionCreated,
            writeClass: .durable,
            payloadHash: "provider-route",
            payload: payload
        )
        _ = try repository.commit(
            expectedLastSequence: 0,
            candidates: [created],
            projections: [:],
            outbox: []
        )

        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: ConversationEncryptionSealingAdapter(
                encryption: encryption,
                conversationID: conversationID
            )
        )
        let providerA = FakeStreamingProvider(tokens: [], finalMessage: "A")
        let providerB = FakeStreamingProvider(tokens: [], finalMessage: "B")
        let configA = ProviderRuntimeConfiguration(
            configurationID: "provider-a",
            baseURL: URL(string: "https://a.example/v1")!,
            model: "model-a",
            apiKey: "key-a"
        )
        let configB = ProviderRuntimeConfiguration(
            configurationID: "provider-b",
            baseURL: URL(string: "https://b.example/v1")!,
            model: "model-b",
            apiKey: "key-b"
        )
        var resolvedConfigurationIDs: [String] = []
        let bridge = SessionRuntimeBridge(
            actor: actor,
            sessionID: conversationID,
            initialState: initial,
            provider: providerA,
            providerConfig: configA,
            providerResolver: { (providerA, configA) },
            providerConfigurationResolver: { configurationID in
                resolvedConfigurationIDs.append(configurationID)
                return configurationID == "provider-b" ? (providerB, configB) : nil
            }
        )

        let didRestore = await bridge.restoreFromRepository(repository)
        XCTAssertTrue(didRestore)
        XCTAssertEqual(resolvedConfigurationIDs, ["provider-b"])
        XCTAssertEqual(bridge.currentRuntimeIdentity, "Native · model-b")
        XCTAssertEqual(bridge.currentRuntimeSelection.providerConfigurationID, "provider-b")
    }

    // MARK: - P0-9：无 Provider 时 send 返回 rejected

    func testSendWithoutProviderReturnsRejected() async {
        let (bridge, _, _) = await Self.makeBridge(provider: nil, skipProvider: true)
        let result = await bridge.send(text: "问题")
        if case .rejected(let reason) = result {
            XCTAssertEqual(reason, .providerUnavailable, "无 Provider 应返回 providerUnavailable")
        } else {
            XCTFail("无 Provider 应 rejected")
        }
    }

    /// 空白消息返回 rejected(.empty)。
    func testSendEmptyReturnsRejected() async {
        let provider = FakeStreamingProvider(tokens: ["x"], finalMessage: "x")
        let (bridge, _, _) = await Self.makeBridge(provider: provider)
        let result = await bridge.send(text: "   ")
        if case .rejected(let reason) = result {
            XCTAssertEqual(reason, .empty)
        } else {
            XCTFail("空白应 rejected(.empty)")
        }
    }

    // MARK: - P0-6：非流式响应（无 delta，仅 onComplete）

    /// Provider 无 delta 直接 onComplete：finalAnswerCompleted 写入 canonical 完整答案。
    func testNonStreamingResponseWritesCanonicalAnswer() async {
        let provider = FakeStreamingProvider(tokens: [], finalMessage: "直接完成")
        let (bridge, _, _) = await Self.makeBridge(provider: provider)

        let done = XCTestExpectation(description: "completed")
        var sawAnswer = false
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: { if case .finalAnswer(let t) = $0 { return t == "直接完成" }; return false }) {
                    sawAnswer = true
                    done.fulfill()
                }
            }
        }
        _ = await bridge.send(text: "问题")

        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(sawAnswer, "非流式响应应写入 canonical 完整答案")
    }

    /// 有 delta 但上游 completion 为空时，canonical answer 必须使用已累积完整 delta。
    func testEmptyCompletionUsesAccumulatedDeltasAsCanonicalAnswer() async {
        let provider = FakeStreamingProvider(tokens: ["部", "分", "答案"], finalMessage: "")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider)
        let done = XCTestExpectation(description: "delta fallback completed")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .finalAnswer(let answer) = $0 { return answer == "部分答案" }
                    return false
                }) {
                    done.fulfill()
                }
            }
        }

        _ = await bridge.send(text: "问题")
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.partialAnswer, "部分答案")
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .completed)
    }

    // MARK: - P0-7：Stop 后迟到回调不污染下一轮

    /// Stop 后迟到的 delta 被丢弃（generation token 不匹配）。
    func testLateDeltaAfterStopIsRejected() async {
        // 慢速 provider：delta 延迟，给 stop 留窗口
        let provider = FakeStreamingProvider(tokens: ["迟", "到"], finalMessage: "迟到", perTokenDelay: 0.3)
        let (bridge, _, _) = await Self.makeBridge(provider: provider)

        let stopped = XCTestExpectation(description: "stopped")
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                if entries.contains(where: { if case .planProgress(let t) = $0 { return t == "已停止" }; return false }) {
                    stopped.fulfill()
                }
            }
        }
        _ = await bridge.send(text: "问题")
        try? await Task.sleep(nanoseconds: 50_000_000)
        await bridge.stop()

        await fulfillment(of: [stopped], timeout: 5)

        // 等待可能的迟到 delta（不应污染任何状态）
        try? await Task.sleep(nanoseconds: 500_000_000)
        let isIdle = await MainActor.run { bridge.isIdle }
        XCTAssertTrue(isIdle, "Stop 后迟到 delta 不应重启 Turn")
    }

    /// 即使 Provider 无视任务取消继续回调，迟到 delta/completion 也不能覆盖 cancelled 终态。
    func testLateCompletionFromUncooperativeProviderIsRejected() async {
        let provider = UncooperativeStreamingProvider()
        let (bridge, actor, _) = await Self.makeBridge(provider: provider)
        let stopped = XCTestExpectation(description: "stopped")
        var rendered: [TimelineSourceEntry] = []
        await MainActor.run {
            bridge.onTimelineUpdate = { entries in
                rendered = entries
                if entries.contains(where: {
                    if case .planProgress(let value) = $0 { return value == "已停止" }
                    return false
                }) {
                    stopped.fulfill()
                }
            }
        }

        _ = await bridge.send(text: "问题")
        try? await Task.sleep(nanoseconds: 20_000_000)
        await bridge.stop()
        await fulfillment(of: [stopped], timeout: 5)
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .cancelled)
        XCTAssertFalse(rendered.contains(where: {
            if case .finalAnswer(let value) = $0 { return value.contains("迟到") }
            return false
        }))
    }

    // MARK: - Durable draft and pending-input queue

    func testPendingDraftSaveCannotReappearAfterTurnConsumesComposerText() async {
        let turnCommitStarted = XCTestExpectation(description: "turn commit entered store")
        let commitGate = DispatchSemaphore(value: 0)
        let store = InMemoryConversationSessionStore()
        store.beforeCommit = { candidates in
            guard candidates.contains(where: { $0.kind == .turnSubmitted }) else { return }
            turnCommitStarted.fulfill()
            commitGate.wait()
        }
        defer { commitGate.signal() }
        let provider = CountingStreamingProvider(message: "完成")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider, store: store)

        bridge.updateDraft("即将发送的草稿")
        let sendTask = Task { await bridge.send(text: "即将发送的草稿") }
        await fulfillment(of: [turnCommitStarted], timeout: 3)
        try? await Task.sleep(nanoseconds: 350_000_000)
        commitGate.signal()

        guard case .accepted = await sendTask.value else {
            return XCTFail("Turn 已落盘后应接管 Composer 原文")
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(actor.latestPublishedState?.session.draft ?? "", "")
        XCTAssertFalse(store.committed.flatMap(\.candidates).contains { envelope in
            envelope.kind == .draftChanged && String(data: envelope.payload, encoding: .utf8) == "即将发送的草稿"
        })
    }

    func testNativeDurableTurnClaimFailureIsReportedAcceptedAndConsumesDraft() async {
        let store = InMemoryConversationSessionStore()
        let provider = CountingStreamingProvider(message: "不得启动")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider, store: store)
        bridge.updateDraft("已经落盘的输入")
        store.rejectNextOutboxClaim = true

        let result = await bridge.send(text: "已经落盘的输入")

        guard case .accepted = result else {
            return XCTFail("Turn 已落盘后不能向 Composer 报告为未发送")
        }
        XCTAssertEqual(provider.invocationCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.activeTurn?.userRequest, "已经落盘的输入")
        XCTAssertEqual(actor.latestPublishedState?.session.draft ?? "", "")
    }

    func testPullQueuedInputAtomicallyMovesTextIntoDraft() async {
        let store = InMemoryConversationSessionStore()
        let provider = CountingStreamingProvider(message: "unused")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider, store: store)
        guard case .queued = await bridge.queue(text: "拉回这条"),
              let queuedID = bridge.queuedInputs.first?.id else {
            return XCTFail("测试队列项必须先落盘")
        }

        let pulled = await bridge.pullQueuedInputToComposer(id: queuedID, expectedDraft: "")

        XCTAssertEqual(pulled, "拉回这条")
        XCTAssertTrue(bridge.queuedInputs.isEmpty)
        XCTAssertEqual(actor.latestPublishedState?.session.draft, "拉回这条")
        XCTAssertTrue(store.committed.contains { batch in
            let kinds = batch.candidates.map(\.kind)
            return kinds == [.queuedInputRemoved, .draftChanged]
        }, "队列删除与 Composer 草稿写入必须属于同一事务")
    }

    func testPullQueuedInputRefusesToOverwriteExistingDraft() async {
        let provider = CountingStreamingProvider(message: "unused")
        let (bridge, _, _) = await Self.makeBridge(provider: provider)
        guard case .queued = await bridge.queue(text: "仍留在队列"),
              let queuedID = bridge.queuedInputs.first?.id else {
            return XCTFail("测试队列项必须先落盘")
        }
        bridge.updateDraft("用户刚输入的内容")

        let pulled = await bridge.pullQueuedInputToComposer(
            id: queuedID,
            expectedDraft: "用户刚输入的内容"
        )

        XCTAssertNil(pulled)
        XCTAssertEqual(bridge.queuedInputs.map(\.text), ["仍留在队列"])
    }

    /// A queue action arriving while a streaming checkpoint is in flight must be sequenced after it,
    /// rather than being built from a stale sequence and permanently blocking the session.
    func testQueueSubmissionSerializesBehindStreamingCheckpoint() async {
        let checkpointStarted = XCTestExpectation(description: "checkpoint entered store")
        let store = CheckpointBlockingConversationStore {
            checkpointStarted.fulfill()
        }
        defer { store.releaseCheckpoint() }
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 1_000_000_000)
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)

        let started = await bridge.send(text: "先执行")
        guard case .accepted = started else {
            return XCTFail("首轮必须启动")
        }
        await fulfillment(of: [checkpointStarted], timeout: 3)

        let queuedTask = Task { await bridge.queue(text: "checkpoint 后排队") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.releaseCheckpoint()
        let queued = await queuedTask.value

        XCTAssertEqual(queued, .queued(position: 1))
        let queuedBeforeStop = bridge.queuedInputs.map(\.text)
        XCTAssertEqual(queuedBeforeStop, ["checkpoint 后排队"])
        await bridge.stop()
        let queuedAfterStop = bridge.queuedInputs.map(\.text)
        let pausedAfterStop = bridge.queueAutoAdvancePaused
        XCTAssertEqual(queuedAfterStop, ["checkpoint 后排队"])
        XCTAssertTrue(pausedAfterStop, "Stop 后必须暂停而不是自动发送队列")
    }

    /// Queue positions must be derived after each earlier serialized commit.
    /// Otherwise two requests waiting behind the same checkpoint both capture
    /// position zero and the second request is inserted ahead of the first.
    func testConcurrentQueueRequestsPreserveFIFOOrder() async {
        let checkpointStarted = XCTestExpectation(description: "checkpoint entered store")
        let store = CheckpointBlockingConversationStore {
            checkpointStarted.fulfill()
        }
        defer { store.releaseCheckpoint() }
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 1_000_000_000)
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)

        guard case .accepted = await bridge.send(text: "先执行") else {
            return XCTFail("首轮必须启动")
        }
        await fulfillment(of: [checkpointStarted], timeout: 3)

        let firstTask = Task { await bridge.queue(text: "第一条") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let secondTask = Task { await bridge.queue(text: "第二条") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.releaseCheckpoint()

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        let queuedTexts = bridge.queuedInputs.map(\.text)
        XCTAssertEqual(firstResult, .queued(position: 1))
        XCTAssertEqual(secondResult, .queued(position: 2))
        XCTAssertEqual(queuedTexts, ["第一条", "第二条"])
        await bridge.stop()
    }

    /// Stop can interleave while the durable start-runtime effect is being
    /// claimed. Once Stop owns settlement, releasing that claim must not start
    /// an external provider request for the cancelled generation.
    func testStopDuringRuntimeClaimPreventsProviderStart() async {
        let claimStarted = XCTestExpectation(description: "runtime claim entered store")
        let claimGate = DispatchSemaphore(value: 0)
        let store = InMemoryConversationSessionStore()
        store.beforeClaimOutboxEffect = { command in
            guard case .startRuntime = command else { return }
            claimStarted.fulfill()
            claimGate.wait()
        }
        defer { claimGate.signal() }
        let provider = CountingStreamingProvider(message: "不应调用")
        let (bridge, actor, _) = await Self.makeBridge(provider: provider, store: store)

        let sendTask = Task { await bridge.send(text: "准备后立即停止") }
        await fulfillment(of: [claimStarted], timeout: 3)
        let stopTask = Task { await bridge.stop() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let queueWhileStopping = await bridge.queue(text: "停止期间不得进入队列")
        claimGate.signal()

        _ = await sendTask.value
        await stopTask.value
        XCTAssertEqual(provider.invocationCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .cancelled)
        XCTAssertEqual(queueWhileStopping, .rejected(reason: .alreadyRunning))
        XCTAssertTrue(bridge.queuedInputs.isEmpty)
    }

    /// 共享 Store 的一次可恢复冲突不能误取消 owner Runtime；队列操作应刷新投影并重试。
    func testQueueConflictRetriesWithoutCancellingActiveRuntime() async {
        let store = InMemoryConversationSessionStore()
        let provider = UncooperativeStreamingProvider()
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)

        guard case .accepted = await bridge.send(text: "当前运行") else {
            return XCTFail("首轮必须启动")
        }
        store.conflictOnNextCommit = true
        let queued = await bridge.queue(text: "冲突后仍保留")

        XCTAssertEqual(queued, .queued(position: 1))
        let isIdle = await MainActor.run { bridge.isIdle }
        XCTAssertFalse(isIdle, "队列冲突重试不能取消当前 Runtime")
        await bridge.stop()
    }

    func testRejectedQueueMutationForcesDurableProjectionRefresh() async {
        let store = ScriptedConversationSessionStore(outcomes: [
            .committed(lastSequence: 2),
            .storageFailure(reason: "queue edit failed")
        ])
        let provider = CountingStreamingProvider(message: "unused")
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)
        var lastTexts: [String] = []
        var lastForceRefresh = false
        bridge.onQueueUpdate = { items, _, forceRefresh in
            lastTexts = items.map(\.text)
            lastForceRefresh = forceRefresh
        }

        guard case .queued = await bridge.queue(text: "持久化正文"),
              let queuedID = bridge.queuedInputs.first?.id
        else {
            return XCTFail("测试队列项必须先成功落盘")
        }
        XCTAssertFalse(lastForceRefresh)

        let edited = await bridge.editQueuedInput(id: queuedID, text: "只存在于界面的正文")

        XCTAssertFalse(edited)
        XCTAssertTrue(lastForceRefresh)
        XCTAssertEqual(lastTexts, ["持久化正文"])
        XCTAssertEqual(bridge.queuedInputs.map(\.text), ["持久化正文"])
    }

    /// 草稿、队列顺序、编辑 revision 与自动衔接状态都来自 durable event replay。
    func testDraftAndQueueRestoreAcrossRepositoryRestart() async throws {
        let conversationID = "conv-queue-restart-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let masterKey = Data((0..<32).map { UInt8((($0 * 13 + 5) % 251) + 1) })
        let encryption = ConversationEncryption(masterKeyData: masterKey)
        var repo1: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 1_000_000_000)
        var bridge1: SessionRuntimeBridge?
        do {
            let assembly = await Self.makeBridge(
                provider: provider,
                store: try XCTUnwrap(repo1),
                conversationID: conversationID
            )
            bridge1 = assembly.bridge

            let firstQueued = await bridge1?.queue(text: "第一条")
            let secondQueued = await bridge1?.queue(text: "第二条")
            XCTAssertEqual(firstQueued, .queued(position: 1))
            XCTAssertEqual(secondQueued, .queued(position: 2))
            let initialQueue = bridge1?.queuedInputs ?? []
            let secondID = try XCTUnwrap(initialQueue.last?.id)
            let edited = await bridge1?.editQueuedInput(id: secondID, text: "第二条已编辑")
            let moved = await bridge1?.setNextQueuedInput(id: secondID)
            let paused = await bridge1?.setQueueAutoAdvancePaused(true)
            XCTAssertTrue(edited == true)
            XCTAssertTrue(moved == true)
            XCTAssertTrue(paused == true)
            bridge1?.updateDraft("重启后仍在的草稿")
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        bridge1 = nil
        repo1 = nil

        let repo2 = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let (bridge2, _, _) = await Self.makeBridge(
            provider: nil,
            store: repo2,
            conversationID: conversationID,
            skipProvider: true
        )
        let restored = await bridge2.restoreFromRepository(repo2)
        XCTAssertTrue(restored)

        let restoredDraft = bridge2.currentDraft
        let restoredPause = bridge2.queueAutoAdvancePaused
        XCTAssertEqual(restoredDraft, "重启后仍在的草稿")
        XCTAssertTrue(restoredPause)
        let restoredQueue = bridge2.queuedInputs
        XCTAssertEqual(restoredQueue.map(\.text), ["第二条已编辑", "第一条"])
        XCTAssertEqual(restoredQueue.map(\.position), [0, 1])
        XCTAssertEqual(restoredQueue.first?.revision, 3, "编辑和移动各递增一次 revision")
    }

    func testRestorePublishesUserDraftMutationInsteadOfStaleReplayedDraft() async throws {
        let conversationID = "conv-draft-restore-race-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(
            masterKeyData: Data(repeating: 0x5D, count: 32)
        )
        var firstRepository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        var firstBridge: SessionRuntimeBridge?
        do {
            let assembly = await Self.makeBridge(
                provider: CountingStreamingProvider(message: "unused"),
                store: try XCTUnwrap(firstRepository),
                conversationID: conversationID
            )
            firstBridge = assembly.bridge
            firstBridge?.updateDraft("磁盘中的旧草稿")
            try? await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(assembly.actor.latestPublishedState?.session.draft, "磁盘中的旧草稿")
        }
        firstBridge = nil
        firstRepository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let assembly = await Self.makeBridge(
            provider: nil,
            store: reopened,
            conversationID: conversationID,
            skipProvider: true,
            restorePending: true
        )
        let bridge = assembly.bridge
        var publishedDrafts: [String] = []
        bridge.onDraftRestored = { publishedDrafts.append($0) }

        // The user clears the editor while repository replay is pending. The
        // empty mutation must win over the older durable value in both the
        // Bridge projection and the UI callback.
        bridge.updateDraft("")
        let restored = await bridge.restoreFromRepository(reopened)

        XCTAssertTrue(restored)
        XCTAssertEqual(bridge.currentDraft, "")
        XCTAssertEqual(publishedDrafts.last, "")
        XCTAssertFalse(publishedDrafts.contains("磁盘中的旧草稿"))
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(assembly.actor.latestPublishedState?.session.draft ?? "", "")
    }

    /// 正常完成只提升一条，并在同一事务中删除 queued revision 与创建新 Turn。
    func testNormalCompletionAtomicallyPromotesOneQueuedInput() async {
        let secondInvocation = XCTestExpectation(description: "queued turn started")
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 180_000_000)
        provider.onInvocation = { count in
            if count == 2 { secondInvocation.fulfill() }
        }
        let store = InMemoryConversationSessionStore()
        let (bridge, _, _) = await Self.makeBridge(provider: provider, store: store)

        guard case .accepted = await bridge.send(text: "第一轮") else {
            return XCTFail("第一轮必须启动")
        }
        let queued = await bridge.queue(text: "下一轮")
        XCTAssertEqual(queued, .queued(position: 1))
        await fulfillment(of: [secondInvocation], timeout: 3)

        let atomicPromotion = store.committed.contains { batch in
            let kinds = Set(batch.candidates.map(\.kind))
            return kinds.contains(.queuedInputRemoved) && kinds.contains(.turnSubmitted)
        }
        XCTAssertTrue(atomicPromotion, "队列删除与新 Turn 必须属于同一 commit batch")
        let queuedCount = bridge.queuedCount
        XCTAssertEqual(queuedCount, 0)
        await bridge.stop()
    }

    func testConcurrentAutoAdvanceRequestsPromoteQueuedInputOnlyOnce() async {
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 2_000_000_000)
        let (bridge, actor, _) = await Self.makeBridge(provider: provider)
        let queued = await bridge.queue(text: "只启动一次")
        XCTAssertEqual(queued, .queued(position: 1))

        async let first = bridge.setQueueAutoAdvancePaused(false)
        async let second = bridge.setQueueAutoAdvancePaused(false)
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])

        for _ in 0..<100 where provider.invocationCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(provider.invocationCount, 1)
        XCTAssertEqual(actor.latestPublishedState?.activeTurn?.userRequest, "只启动一次")
        XCTAssertTrue(bridge.queuedInputs.isEmpty)
        await bridge.stop()
    }

    func testQueuedTurnUsesProviderBindingCapturedAtEnqueueTime() async {
        let queuedTurnStarted = XCTestExpectation(description: "queued turn uses original provider")
        let originalProvider = DelayedCountingStreamingProvider(delayNanoseconds: 180_000_000)
        originalProvider.onInvocation = { count in
            if count == 2 { queuedTurnStarted.fulfill() }
        }
        let replacementProvider = CountingStreamingProvider(message: "replacement")
        let (bridge, _, _) = await Self.makeBridge(provider: originalProvider)

        guard case .accepted = await bridge.send(text: "第一轮") else {
            return XCTFail("第一轮必须启动")
        }
        let queuedResult = await bridge.queue(text: "冻结供应商的第二轮")
        XCTAssertEqual(queuedResult, .queued(position: 1))
        bridge.setProvider(
            replacementProvider,
            config: ProviderRuntimeConfiguration(
                configurationID: "replacement",
                configurationRevision: 2,
                baseURL: URL(string: "https://replacement.example.com/v1")!,
                model: "replacement-model",
                apiKey: "replacement-key"
            )
        )

        await fulfillment(of: [queuedTurnStarted], timeout: 3)
        XCTAssertEqual(originalProvider.invocationCount, 2)
        XCTAssertEqual(replacementProvider.invocationCount, 0)
        await bridge.stop()
    }

    func testSharedActorBridgesQueueAndStopTheSameDurableTurn() async {
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 2_000_000_000)
        let store = InMemoryConversationSessionStore()
        let initial = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initial,
            store: store,
            sealing: TestConversationSealing()
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let (ownerBridge, observerBridge) = await MainActor.run {
            (
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initial,
                    provider: provider,
                    providerConfig: config
                ),
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initial,
                    provider: provider,
                    providerConfig: config
                )
            )
        }
        let observerSawStreaming = XCTestExpectation(description: "observer sees shared running state")
        let ownerSawCancellation = XCTestExpectation(description: "owner settles observer stop")
        await MainActor.run {
            observerBridge.onRunPhaseUpdate = { phase in
                if phase == .streaming { observerSawStreaming.fulfill() }
            }
            ownerBridge.onTimelineUpdate = { entries in
                if entries.contains(where: {
                    if case .planProgress(let value) = $0 { return value == "已停止" }
                    return false
                }) {
                    ownerSawCancellation.fulfill()
                }
            }
        }

        guard case .accepted = await ownerBridge.send(text: "共享运行") else {
            return XCTFail("owner 必须启动运行")
        }
        await fulfillment(of: [observerSawStreaming], timeout: 3)
        let observerIsIdle = observerBridge.isIdle
        XCTAssertFalse(observerIsIdle)

        let queued = await observerBridge.send(text: "从另一个窗口排队")
        XCTAssertEqual(queued, .queued(position: 1))
        await observerBridge.stop()
        await fulfillment(of: [ownerSawCancellation], timeout: 3)

        XCTAssertEqual(actor.latestPublishedState?.phase, .cancelled)
        let preservedQueue = observerBridge.queuedInputs.map(\.text)
        let paused = observerBridge.queueAutoAdvancePaused
        XCTAssertEqual(preservedQueue, ["从另一个窗口排队"])
        XCTAssertTrue(paused)
    }

    func testSecondWindowRestoreDoesNotInterruptLiveSharedActorRuntime() async throws {
        let conversationID = "conv-live-shared-\(UUID().uuidString)"
        let repository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: tempDBPath(),
            encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x57, count: 32))
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: TestConversationSealing()
        )
        let ownerProvider = DelayedCountingStreamingProvider(delayNanoseconds: 2_000_000_000)
        let observerProvider = CountingStreamingProvider(message: "不得调用")
        let configuration = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let (owner, observer) = await MainActor.run {
            (
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: conversationID,
                    initialState: initial,
                    provider: ownerProvider,
                    providerConfig: configuration
                ),
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: conversationID,
                    initialState: initial,
                    provider: observerProvider,
                    providerConfig: configuration,
                    restorePending: true
                )
            )
        }
        guard case .accepted = await owner.send(text: "持续运行") else {
            return XCTFail("owner 必须先启动 Runtime")
        }

        let restored = await observer.restoreFromRepository(repository)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(restored)
        XCTAssertEqual(ownerProvider.invocationCount, 1)
        XCTAssertEqual(observerProvider.invocationCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .streaming)
        XCTAssertFalse(try repository.loadEvents().contains {
            $0.kind == .attemptInterruptedByRelaunch
        })
        await owner.stop()
    }

    func testSharedObserverStartsNextTurnWithMonotonicIdentity() async {
        let store = InMemoryConversationSessionStore()
        let initial = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initial,
            store: store,
            sealing: TestConversationSealing()
        )
        let configuration = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let ownerProvider = DelayedCountingStreamingProvider(delayNanoseconds: 80_000_000)
        let observerProvider = CountingStreamingProvider(message: "second")
        let owner = SessionRuntimeBridge(
            actor: actor,
            sessionID: "c-1",
            initialState: initial,
            provider: ownerProvider,
            providerConfig: configuration
        )
        let observer = SessionRuntimeBridge(
            actor: actor,
            sessionID: "c-1",
            initialState: initial,
            provider: observerProvider,
            providerConfig: configuration
        )
        let observerSawFirstTurnFinish = expectation(description: "observer projects first turn terminal state")
        var observerSawActivePhase = false
        var observerReportedTerminal = false
        observer.onRunPhaseUpdate = { phase in
            if phase != .idle {
                observerSawActivePhase = true
            } else if observerSawActivePhase, observerReportedTerminal == false {
                observerReportedTerminal = true
                observerSawFirstTurnFinish.fulfill()
            }
        }

        guard case .accepted(let firstTurnID) = await owner.send(text: "第一轮") else {
            return XCTFail("owner first turn must start")
        }
        XCTAssertEqual(firstTurnID, "turn-1")
        await fulfillment(of: [observerSawFirstTurnFinish], timeout: 3)

        guard case .accepted(let secondTurnID) = await observer.send(text: "第二轮") else {
            return XCTFail("observer next turn must start")
        }
        XCTAssertEqual(secondTurnID, "turn-2")
        XCTAssertEqual(actor.latestPublishedState?.activeTurn?.ordinal, 2)
        XCTAssertEqual(actor.latestPublishedState?.activeTurn?.id, "turn-2")
        for _ in 0..<100 where observer.isIdle == false {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 观察窗口的 Stop 即使第一次提交遇到共享 Store 冲突，也必须重试，不能把会话误标为存储故障。
    func testSharedObserverStopRetriesConflictWithoutBlockingSession() async {
        let store = InMemoryConversationSessionStore()
        let initial = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initial,
            store: store,
            sealing: TestConversationSealing()
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let provider = UncooperativeStreamingProvider()
        let (owner, observer) = await MainActor.run {
            (
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initial,
                    provider: provider,
                    providerConfig: config
                ),
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initial,
                    provider: provider,
                    providerConfig: config
                )
            )
        }
        guard case .accepted = await owner.send(text: "共享停止") else {
            return XCTFail("owner 必须启动运行")
        }
        store.conflictOnNextCommit = true
        await observer.stop()

        // owner 的状态观察者随后完成取消终态；不应被 observer 的一次冲突阻断。
        for _ in 0..<100 {
            if actor.latestPublishedState?.phase == .cancelled { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(actor.latestPublishedState?.phase, .cancelled)
    }

    func testSimultaneousSharedActorSendsPreserveLosingMessageInQueue() async {
        let store = InMemoryConversationSessionStore()
        let initial = Self.makeInitialState()
        let actor = ConversationSessionActor(
            sessionID: "c-1",
            initialState: initial,
            store: store,
            sealing: TestConversationSealing()
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let firstProvider = DelayedCountingStreamingProvider(delayNanoseconds: 2_000_000_000)
        let secondProvider = DelayedCountingStreamingProvider(delayNanoseconds: 2_000_000_000)
        let (firstBridge, secondBridge) = await MainActor.run {
            (
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initial,
                    provider: firstProvider,
                    providerConfig: config
                ),
                SessionRuntimeBridge(
                    actor: actor,
                    sessionID: "c-1",
                    initialState: initial,
                    provider: secondProvider,
                    providerConfig: config
                )
            )
        }

        async let firstResult = firstBridge.send(text: "窗口一")
        async let secondResult = secondBridge.send(text: "窗口二")
        let results = await [firstResult, secondResult]
        let acceptedCount = results.filter {
            if case .accepted = $0 { return true }
            return false
        }.count
        let queuedCount = results.filter {
            if case .queued = $0 { return true }
            return false
        }.count

        XCTAssertEqual(acceptedCount, 1)
        XCTAssertEqual(queuedCount, 1)
        XCTAssertEqual(actor.latestPublishedState?.session.queuedInputs.count, 1)
        await firstBridge.stop()
        await secondBridge.stop()
    }

    func testRestoredQueuePausesWhenProviderSnapshotNoLongerMatches() async throws {
        let conversationID = "queue-rebind-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let masterKey = Data((0..<32).map { UInt8((($0 * 13 + 5) % 251) + 1) })
        let encryption = ConversationEncryption(masterKeyData: masterKey)

        var firstRepository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        var firstBridge: SessionRuntimeBridge? = await Self.makeBridge(
            provider: CountingStreamingProvider(message: "unused"),
            store: try XCTUnwrap(firstRepository),
            conversationID: conversationID
        ).bridge
        let firstQueueResult = await firstBridge?.queue(text: "需要重新绑定")
        XCTAssertEqual(firstQueueResult, .queued(position: 1))
        let firstPauseResult = await firstBridge?.setQueueAutoAdvancePaused(true)
        XCTAssertEqual(firstPauseResult, true)
        firstBridge = nil
        firstRepository = nil

        let secondRepository = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let replacementProvider = CountingStreamingProvider(message: "must not run")
        let (secondBridge, _, _) = await Self.makeBridge(
            provider: replacementProvider,
            store: secondRepository,
            conversationID: conversationID
        )
        let restored = await secondBridge.restoreFromRepository(secondRepository)
        XCTAssertTrue(restored)
        secondBridge.setProvider(
            replacementProvider,
            config: ProviderRuntimeConfiguration(
                configurationID: "changed",
                configurationRevision: 9,
                baseURL: URL(string: "https://changed.example.com/v1")!,
                model: "changed-model",
                apiKey: "changed-key"
            )
        )

        let resumed = await secondBridge.setQueueAutoAdvancePaused(false)
        XCTAssertTrue(resumed)
        let restoredInput = secondBridge.queuedInputs.first
        XCTAssertEqual(restoredInput?.revalidationState, .needsRebind)
        let paused = secondBridge.queueAutoAdvancePaused
        XCTAssertTrue(paused)
        XCTAssertEqual(replacementProvider.invocationCount, 0)

        let inputRequiringRebind = try XCTUnwrap(restoredInput)
        let rebindSummary = secondBridge.queuedInputRebindSummary(for: inputRequiringRebind)
        XCTAssertTrue(rebindSummary.contains("供应商、模型或凭证已变化"))
        let rebound = await secondBridge.resolveQueuedInputRebind(
            id: inputRequiringRebind.id,
            choice: .bindToCurrentSessionContext
        )
        XCTAssertTrue(rebound)
        XCTAssertEqual(secondBridge.queuedInputs.first?.revalidationState, .valid)
        XCTAssertEqual(secondBridge.queuedInputs.first?.revision, (restoredInput?.revision ?? 0) + 1)

        let resumedAfterRebind = await secondBridge.setQueueAutoAdvancePaused(false)
        XCTAssertTrue(resumedAfterRebind)
        for _ in 0..<100 where replacementProvider.invocationCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(replacementProvider.invocationCount, 1)
    }

    func testEndpointPathChangesDerivedConfigurationIdentityAndDigest() {
        let first = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1/")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let equivalent = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://API.EXAMPLE.COM:443/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let coding = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/coding/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let firstSelection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: first.effectiveConfigurationID,
            modelID: first.model
        )
        let codingSelection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: coding.effectiveConfigurationID,
            modelID: coding.model
        )

        XCTAssertEqual(first.effectiveConfigurationID, equivalent.effectiveConfigurationID)
        XCTAssertNotEqual(first.effectiveConfigurationID, coding.effectiveConfigurationID)
        XCTAssertNotEqual(
            SessionRuntimeBridge.providerConfigurationDigest(
                selection: firstSelection,
                configuration: first
            ),
            SessionRuntimeBridge.providerConfigurationDigest(
                selection: codingSelection,
                configuration: coding
            )
        )
    }

    func testOriginOnlyLegacyQueuedSnapshotStillPromotesAfterUpgrade() async throws {
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let legacyID = "runtime-(String(hash, radix: 16))"
        XCTAssertTrue(config.legacyConfigurationIDs.contains(legacyID))
        XCTAssertNotEqual(legacyID, config.effectiveConfigurationID)
        let selection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: legacyID,
            modelID: config.model
        )
        let configurationDigest = SessionRuntimeBridge.legacyProviderConfigurationDigest(
            selection: selection,
            configuration: config
        )
        let authenticationDigest = SessionRuntimeBridge.providerAuthenticationDigest(
            config,
            selection: selection
        )
        let authentication = RuntimeAuthenticationSnapshot(
            mode: .stacioCredentialBindings,
            configurationID: legacyID,
            configurationRevision: config.configurationRevision,
            normalizedModelOrigin: WebsiteActionResolver.normalizedOrigin(url: config.baseURL),
            verificationFingerprint: configurationDigest,
            generationIDsByRole: ["apiKey": config.credentialGenerationID!],
            createdAt: Date(timeIntervalSince1970: 1),
            digest: authenticationDigest
        )
        var initial = Self.makeInitialState()
        initial.session.queueAutoAdvancePaused = true
        let runtimeSettings = try AssistantRuntimeSettingsSnapshot.resolve(from: nil)
        let toolAuthorizationPolicy = AgentToolAuthorizationPolicySnapshot(
            globalPolicy: .requireConfirmationForAll,
            commandPolicy: AgentCommandPatternPolicy(),
            automationPolicy: SessionAutomationPolicy(
                environment: "development",
                aiExecutionPolicy: "requireEveryCommand"
            ),
            targetRuntimeID: initial.session.targetBinding.connectionID,
            targetRuntimeGeneration: nil,
            targetBindingDigest: initial.session.targetBinding.digest,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        initial.session.queuedInputs = [QueuedInput(
            id: "legacy-queued",
            sessionID: initial.session.id,
            revision: 1,
            position: 0,
            text: "继续旧队列",
            contextSnapshot: QueuedInputContextSnapshot(
                targetBindingSnapshot: initial.session.targetBinding,
                targetWorkingDirectory: initial.session.targetBinding.targetWorkingDirectory,
                targetDigest: initial.session.targetBinding.digest,
                runtimeSelectionSnapshot: selection,
                providerConfigurationID: legacyID,
                modelID: config.model,
                runtimeAuthenticationSnapshot: authentication,
                authenticationDigest: authenticationDigest,
                configurationRevisionDigest: configurationDigest,
                workMode: .agent,
                terminalMode: TurnExecutionChoice.realTerminal.rawValue,
                policyRevision: "assistant-settings-\(runtimeSettings.registryRevision)",
                instructionDigest: runtimeSettings.instructionDigest,
                runtimeSettingsSnapshot: runtimeSettings,
                toolAuthorizationPolicySnapshot: toolAuthorizationPolicy,
                capturedAt: Date(timeIntervalSince1970: 1),
                source: .sessionDefault
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )]
        let store = InMemoryConversationSessionStore()
        let actor = ConversationSessionActor(
            sessionID: initial.session.id,
            initialState: initial,
            store: store,
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "已继续")
        let initialState = initial
        let sessionID = initial.session.id
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: sessionID,
                initialState: initialState,
                provider: provider,
                providerConfig: config
            )
        }

        let resumed = await bridge.setQueueAutoAdvancePaused(false)
        XCTAssertTrue(resumed)
        for _ in 0..<100 where provider.invocationCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(provider.invocationCount, 1)
    }

    func testLegacyQueuedSnapshotMissingFrozenSettingsPausesForExplicitRebind() async throws {
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let selection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: config.effectiveConfigurationID,
            modelID: config.model
        )
        let configurationDigest = SessionRuntimeBridge.providerConfigurationDigest(
            selection: selection,
            configuration: config
        )
        let authenticationDigest = SessionRuntimeBridge.providerAuthenticationDigest(
            config,
            selection: selection
        )
        let authentication = RuntimeAuthenticationSnapshot(
            mode: .stacioCredentialBindings,
            configurationID: config.effectiveConfigurationID,
            configurationRevision: config.configurationRevision,
            normalizedModelOrigin: WebsiteActionResolver.normalizedOrigin(url: config.baseURL),
            verificationFingerprint: configurationDigest,
            generationIDsByRole: ["apiKey": config.credentialGenerationID!],
            createdAt: Date(timeIntervalSince1970: 1),
            digest: authenticationDigest
        )
        var initial = Self.makeInitialState()
        initial.session.queueAutoAdvancePaused = true
        let toolAuthorizationPolicy = AgentToolAuthorizationPolicySnapshot(
            globalPolicy: .requireConfirmationForAll,
            commandPolicy: AgentCommandPatternPolicy(),
            automationPolicy: SessionAutomationPolicy(
                environment: "development",
                aiExecutionPolicy: "requireEveryCommand"
            ),
            targetRuntimeID: initial.session.targetBinding.connectionID,
            targetRuntimeGeneration: nil,
            targetBindingDigest: initial.session.targetBinding.digest,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        initial.session.queuedInputs = [QueuedInput(
            id: "legacy-missing-settings",
            sessionID: initial.session.id,
            revision: 1,
            position: 0,
            text: "不得静默采用当前设置",
            contextSnapshot: QueuedInputContextSnapshot(
                targetBindingSnapshot: initial.session.targetBinding,
                targetWorkingDirectory: initial.session.targetBinding.targetWorkingDirectory,
                targetDigest: initial.session.targetBinding.digest,
                runtimeSelectionSnapshot: selection,
                providerConfigurationID: config.effectiveConfigurationID,
                modelID: config.model,
                runtimeAuthenticationSnapshot: authentication,
                authenticationDigest: authenticationDigest,
                configurationRevisionDigest: configurationDigest,
                workMode: .agent,
                terminalMode: TurnExecutionChoice.realTerminal.rawValue,
                runtimeSettingsSnapshot: nil,
                toolAuthorizationPolicySnapshot: toolAuthorizationPolicy,
                capturedAt: Date(timeIntervalSince1970: 1),
                source: .sessionDefault
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )]
        let actor = ConversationSessionActor(
            sessionID: initial.session.id,
            initialState: initial,
            store: InMemoryConversationSessionStore(),
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "must not run")
        let bridge = SessionRuntimeBridge(
            actor: actor,
            sessionID: initial.session.id,
            initialState: initial,
            provider: provider,
            providerConfig: config
        )

        let resumed = await bridge.setQueueAutoAdvancePaused(false)
        XCTAssertTrue(resumed)
        XCTAssertEqual(provider.invocationCount, 0)
        XCTAssertEqual(bridge.queuedInputs.first?.revalidationState, .needsRebind)
        XCTAssertTrue(bridge.queueAutoAdvancePaused)
        let queued = try XCTUnwrap(bridge.queuedInputs.first)
        XCTAssertTrue(
            bridge.queuedInputRebindSummary(for: queued)
                .contains("缺少入队时的运行设置快照")
        )

        let unsafeOriginal = await bridge.resolveQueuedInputRebind(
            id: queued.id,
            choice: .sendWithOriginalContext
        )
        XCTAssertFalse(unsafeOriginal)
        XCTAssertEqual(bridge.queuedInputs.first?.revalidationState, .needsRebind)

        let rebound = await bridge.resolveQueuedInputRebind(
            id: queued.id,
            choice: .bindToCurrentSessionContext
        )
        XCTAssertTrue(rebound)
        XCTAssertNotNil(bridge.queuedInputs.first?.contextSnapshot.runtimeSettingsSnapshot)
        XCTAssertNotNil(bridge.queuedInputs.first?.contextSnapshot.toolAuthorizationPolicySnapshot)

        let resumedAfterRebind = await bridge.setQueueAutoAdvancePaused(false)
        XCTAssertTrue(resumedAfterRebind)
        for _ in 0..<100 where provider.invocationCount == 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(provider.invocationCount, 1)
    }

    /// Stop 是非成功终态：保留整个队列、持久化暂停状态且绝不启动第二次 Provider 请求。
    func testStopPausesAutoAdvanceAndPreservesQueue() async {
        let provider = DelayedCountingStreamingProvider(delayNanoseconds: 2_000_000_000)
        let (bridge, _, _) = await Self.makeBridge(provider: provider)

        guard case .accepted = await bridge.send(text: "当前轮") else {
            return XCTFail("当前轮必须启动")
        }
        let queued = await bridge.queue(text: "不要自动执行")
        XCTAssertEqual(queued, .queued(position: 1))
        await bridge.stop()

        let queuedTexts = bridge.queuedInputs.map(\.text)
        let paused = bridge.queueAutoAdvancePaused
        XCTAssertEqual(provider.invocationCount, 1)
        XCTAssertEqual(queuedTexts, ["不要自动执行"])
        XCTAssertTrue(paused)
    }

    // MARK: - P0-8：Timeline 可见 cell 文本

    /// Timeline apply 后能读取可见 cell 文本（不只 itemCount）。
    @MainActor
    func testTimelineVisibleCellText() {
        let vc = ConversationTimelineViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        window.contentView?.layoutSubtreeIfNeeded()
        vc.apply(entries: [
            .userMessage("用户消息"),
            .finalAnswer("助手回答")
        ])
        window.contentView?.layoutSubtreeIfNeeded()
        vc.view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(vc.itemCount, 2)
        let text0 = vc.visibleCellText(at: 0)
        let text1 = vc.visibleCellText(at: 1)
        XCTAssertNotNil(text0, "应能读取 cell 0 文本")
        XCTAssertNotNil(text1, "应能读取 cell 1 文本")
        XCTAssertTrue(text0?.contains("用户消息") == true, "cell 0 应含用户消息")
        XCTAssertTrue(text1?.contains("助手回答") == true, "cell 1 应含助手回答")
    }

    /// 重复文本必须物化成两个独立 cell，流式增长必须保留 identity 并增加高度。
    @MainActor
    func testTimelineSupportsDuplicateTextAndStreamingGrowth() {
        let vc = ConversationTimelineViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentViewController = vc
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }

        vc.apply(entries: [.userMessage("重复"), .userMessage("重复"), .finalAnswer("短")])
        window.contentView?.layoutSubtreeIfNeeded()
        vc.view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let answerID = vc.entryID(at: 2)
        let shortHeight = vc.visibleCellFrame(at: 2)?.height ?? 0
        XCTAssertEqual(vc.visibleCellText(at: 0), "重复")
        XCTAssertEqual(vc.visibleCellText(at: 1), "重复")

        let longAnswer = String(repeating: "流式内容持续增长并自动换行。", count: 18)
        vc.apply(entries: [.userMessage("重复"), .userMessage("重复"), .finalAnswer(longAnswer)])
        window.contentView?.layoutSubtreeIfNeeded()
        vc.view.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(vc.itemCount, 3)
        XCTAssertEqual(vc.entryID(at: 2), answerID, "流式增长不能更换领域条目 identity")
        XCTAssertEqual(vc.visibleCellText(at: 2), longAnswer)
        XCTAssertGreaterThan(vc.visibleCellFrame(at: 2)?.height ?? 0, shortHeight)
    }

    // MARK: - 辅助

    private func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("v2-prod-test-\(UUID().uuidString).sqlite3").path
    }

    @discardableResult
    private func seedApprovedToolState(
        repository: ConversationRepositoryV2,
        conversationID: String,
        proposalID: String
    ) throws -> String {
        let initial = Self.makeInitialState(conversationID: conversationID)
        let targetContext = Self.recoveryToolTargetContext
        let targetBinding = Self.recoveryToolTargetBinding
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: ConversationEncryptionSealingAdapter(
                encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x01, count: 32)),
                conversationID: conversationID
            )
        )
        // The repository performs the authoritative encryption. This sealing
        // adapter only proves that the Actor's pre-commit round trip is usable.
        let toolPayload = ConversationToolProposalPayload(
            proposalID: proposalID,
            invocationID: "invocation-1",
            batchID: "batch-1",
            ordinal: 1,
            command: "pwd",
            explanation: "读取当前目录",
            risk: "readOnly",
            targetRuntimeID: targetContext.runtimeID,
            targetRuntimeGeneration: targetContext.connectionGeneration,
            targetTitle: targetContext.title
        )
        let providerConfiguration = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let runtimeSelection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: providerConfiguration.effectiveConfigurationID,
            modelID: providerConfiguration.model
        )
        let configurationDigest = SessionRuntimeBridge.providerConfigurationDigest(
            selection: runtimeSelection,
            configuration: providerConfiguration
        )
        let authenticationDigest = SessionRuntimeBridge.providerAuthenticationDigest(
            providerConfiguration,
            selection: runtimeSelection
        )
        let authenticationSnapshot = RuntimeAuthenticationSnapshot(
            mode: .stacioCredentialBindings,
            configurationID: providerConfiguration.effectiveConfigurationID,
            configurationRevision: providerConfiguration.configurationRevision,
            normalizedModelOrigin: WebsiteActionResolver.normalizedOrigin(
                url: providerConfiguration.baseURL
            ),
            verificationFingerprint: configurationDigest,
            generationIDsByRole: ["apiKey": providerConfiguration.credentialGenerationID!],
            createdAt: Date(timeIntervalSince1970: 1),
            digest: authenticationDigest
        )
        let toolCatalog = try XCTUnwrap(BundledRuntimeCatalog.shared.toolCatalog)
        let toolCapabilitySnapshot = ToolCapabilitySnapshot(
            catalogRevision: toolCatalog.revision,
            enabledToolIDs: [StacioBuiltinToolID.terminalCommand],
            targetBindingDigest: targetBinding.digest
        )
        let submitted = TurnSubmittedPayload(
            text: "检查目录",
            runtimeSelection: runtimeSelection,
            targetBinding: targetBinding,
            targetRuntimeGeneration: targetContext.connectionGeneration,
            terminalMode: TurnExecutionChoice.realTerminal.rawValue,
            ordinal: 1,
            runtimeAuthenticationSnapshot: authenticationSnapshot,
            configurationRevisionDigest: configurationDigest,
            toolCapabilitySnapshot: toolCapabilitySnapshot
        )
        let firstSpecs: [(ConversationEventKind, Data, ConversationEventScope, String)] = [
            (
                .turnSubmitted,
                EventPayloadCodec.encode(submitted) ?? Data(),
                .turn,
                "user"
            ),
            (.admissionRequested, Data(), .attempt, "runtime"),
            (.admissionGranted, Data(), .attempt, "runtime"),
            (.runtimeStarted, Data(), .attempt, "runtime"),
            (
                .toolProposed,
                EventPayloadCodec.encode(ConversationToolProposalBatchPayload(proposals: [toolPayload])) ?? Data(),
                .attempt,
                "provider"
            ),
            (.approvalRequested, Data(), .attempt, "runtime")
        ]
        let firstDrafts = firstSpecs.enumerated().map { index, spec in
            seededDraft(
                conversationID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1",
                sequence: index + 1,
                kind: spec.0,
                payload: spec.1,
                scope: spec.2,
                source: spec.3
            )
        }
        guard case .committed(let awaitingApprovalState) = actor.submitSync(firstDrafts),
              let decisionID = awaitingApprovalState.activeAttempt?.pendingDecisionIDs.first else {
            throw ConversationOutboxStoreError.invalidCommandPayload("seed approval state")
        }
        try settleSeededEffect(
            .requestAdmission(
                sessionID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1"
            ),
            repository: repository
        )
        try settleSeededEffect(
            .startRuntime(attemptID: "attempt-1"),
            repository: repository
        )

        let approval = ApprovalResolutionPayload(
            decisionID: decisionID,
            approved: true,
            resolutionSource: "user"
        )
        let approvalDraft = seededDraft(
            conversationID: conversationID,
            turnID: "turn-1",
            attemptID: "attempt-1",
            sequence: 7,
            kind: .approvalResolved,
            payload: EventPayloadCodec.encode(approval) ?? Data(),
            scope: .attempt,
            source: "user"
        )
        guard case .committed = actor.submitSync([approvalDraft]) else {
            throw ConversationOutboxStoreError.invalidCommandPayload("seed approved state")
        }
        try settleSeededEffect(
            .resolveDecision(decisionID: decisionID, outcome: .approved, source: "user"),
            repository: repository
        )
        return ConversationEffectOutboxFactory.stableEffectID(
            for: .executeTool(attemptID: "attempt-1", proposalID: proposalID)
        )
    }

    private static var recoveryToolTargetContext: AITerminalContext {
        AITerminalContext(
            runtimeID: "local",
            connectionGeneration: 1,
            historyScopeID: "recovery-tool-scope",
            title: "Local",
            currentDirectory: "~",
            recentTranscript: ""
        )
    }

    private static var recoveryToolTargetBinding: TargetBinding {
        let context = recoveryToolTargetContext
        let digest = recoveryToolStableDigest(
            [context.historyScopeID, context.title, context.currentDirectory ?? ""]
                .joined(separator: "|")
        )
        return TargetBinding(
            id: "target-\(recoveryToolStableDigest(context.historyScopeID))",
            revision: 2,
            digest: digest,
            connectionID: context.runtimeID,
            connectionKind: "local",
            remoteIdentity: context.title,
            hostKeyFingerprint: nil,
            host: context.title,
            user: "",
            port: 0,
            targetWorkingDirectory: context.currentDirectory ?? "~"
        )
    }

    private static func recoveryToolStableDigest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func seedAwaitingApprovalState(
        repository: ConversationRepositoryV2,
        conversationID: String,
        proposalID: String
    ) throws {
        let initial = Self.makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: repository,
            sealing: ConversationEncryptionSealingAdapter(
                encryption: ConversationEncryption(masterKeyData: Data(repeating: 0x01, count: 32)),
                conversationID: conversationID
            )
        )
        let providerConfiguration = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let runtimeSelection = AgentRuntimeSelection(
            kind: .nativeAPI,
            providerConfigurationID: providerConfiguration.effectiveConfigurationID,
            modelID: providerConfiguration.model
        )
        let configurationDigest = SessionRuntimeBridge.providerConfigurationDigest(
            selection: runtimeSelection,
            configuration: providerConfiguration
        )
        let authenticationDigest = SessionRuntimeBridge.providerAuthenticationDigest(
            providerConfiguration,
            selection: runtimeSelection
        )
        let authenticationSnapshot = RuntimeAuthenticationSnapshot(
            mode: .stacioCredentialBindings,
            configurationID: providerConfiguration.effectiveConfigurationID,
            configurationRevision: providerConfiguration.configurationRevision,
            normalizedModelOrigin: WebsiteActionResolver.normalizedOrigin(url: providerConfiguration.baseURL),
            verificationFingerprint: configurationDigest,
            generationIDsByRole: ["apiKey": providerConfiguration.credentialGenerationID!],
            createdAt: Date(timeIntervalSince1970: 1),
            digest: authenticationDigest
        )
        let toolPayload = ConversationToolProposalPayload(
            proposalID: proposalID,
            invocationID: "invocation-relaunch",
            batchID: "batch-relaunch",
            ordinal: 1,
            command: "pwd",
            explanation: "读取当前目录",
            risk: "readOnly",
            targetRuntimeID: "local",
            targetTitle: "Local"
        )
        let submitted = TurnSubmittedPayload(
            text: "检查目录",
            runtimeSelection: runtimeSelection,
            targetBinding: initial.session.targetBinding,
            terminalMode: TurnExecutionChoice.realTerminal.rawValue,
            ordinal: 1,
            runtimeAuthenticationSnapshot: authenticationSnapshot,
            configurationRevisionDigest: configurationDigest
        )
        let specs: [(ConversationEventKind, Data, ConversationEventScope, String)] = [
            (.turnSubmitted, EventPayloadCodec.encode(submitted) ?? Data(), .turn, "user"),
            (.admissionRequested, Data(), .attempt, "runtime"),
            (.admissionGranted, Data(), .attempt, "runtime"),
            (.runtimeStarted, Data(), .attempt, "runtime"),
            (
                .toolProposed,
                EventPayloadCodec.encode(ConversationToolProposalBatchPayload(proposals: [toolPayload])) ?? Data(),
                .attempt,
                "provider"
            ),
            (.approvalRequested, Data(), .attempt, "runtime")
        ]
        let drafts = specs.enumerated().map { index, spec in
            seededDraft(
                conversationID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1",
                sequence: index + 1,
                kind: spec.0,
                payload: spec.1,
                scope: spec.2,
                source: spec.3
            )
        }
        guard case .committed(let state) = actor.submitSync(drafts),
              state.phase == .awaitingApproval else {
            throw ConversationOutboxStoreError.invalidCommandPayload("seed awaiting approval state")
        }
        try settleSeededEffect(
            .requestAdmission(sessionID: conversationID, turnID: "turn-1", attemptID: "attempt-1"),
            repository: repository
        )
        try settleSeededEffect(
            .startRuntime(attemptID: "attempt-1"),
            repository: repository
        )
    }

    private func seededDraft(
        conversationID: String,
        turnID: String,
        attemptID: String,
        sequence: Int,
        kind: ConversationEventKind,
        payload: Data,
        scope: ConversationEventScope,
        source: String
    ) -> EventDraft {
        EventDraft(
            envelope: ConversationEventEnvelope(
                eventID: "seed-\(sequence)",
                conversationID: conversationID,
                scope: scope,
                turnID: turnID,
                attemptID: attemptID,
                candidateSequence: sequence,
                source: source,
                timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
                kind: kind,
                writeClass: .durable,
                payloadHash: "seed-hash-\(sequence)",
                payload: payload
            ),
            expectedLastSequence: sequence - 1
        )
    }

    private func settleSeededEffect(
        _ command: EffectCommand,
        repository: ConversationRepositoryV2
    ) throws {
        let effectID = ConversationEffectOutboxFactory.stableEffectID(for: command)
        let token = "seed-\(effectID)"
        let claimed = try XCTUnwrap(repository.claimOutboxEffect(
            effectID: effectID,
            dispatchToken: token,
            dispatchedAt: "2026-08-10T00:00:00Z"
        ))
        XCTAssertEqual(claimed.command, command)
        XCTAssertTrue(try repository.settleOutbox(
            itemID: claimed.itemID,
            dispatchToken: token,
            outcome: .acknowledged,
            settledAt: "2026-08-10T00:00:01Z"
        ))
    }

    private func assertLocalAgentRuntimeRecoveryDoesNotRedispatch(
        claimBeforeRestart: Bool
    ) async throws {
        let conversationID = "conv-local-agent-recovery-\(UUID().uuidString)"
        let dbPath = tempDBPath()
        let encryption = ConversationEncryption(masterKeyData: Data(repeating: 0x68, count: 32))
        var repository: ConversationRepositoryV2? = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let initial = Self.makeInitialState(conversationID: conversationID)
        let configuration = Self.makeLocalAgentConfiguration()
        let selection = AgentRuntimeSelection(
            kind: .localAgent,
            localAgentConfigurationID: configuration.configurationID,
            localAgentExecutionProfileID: configuration.executionProfileID,
            localAgentExecutionProfileKind: .terminalPassthrough,
            workMode: .agent,
            revision: initial.session.runtimeSelection.revision + 1
        )
        let submitted = TurnSubmittedPayload(
            text: "inspect nginx",
            runtimeSelection: selection,
            targetBinding: initial.session.targetBinding,
            terminalMode: LocalAgentExecutionProfileKind.terminalPassthrough.rawValue,
            ordinal: 1,
            configurationRevisionDigest: "local-agent-config-revision"
        )
        let specs: [(ConversationEventKind, Data, ConversationEventScope, String)] = [
            (
                .runtimeSelectionChanged,
                EventPayloadCodec.encode(RuntimeSelectionChangedPayload(selection: selection)) ?? Data(),
                .session,
                "user"
            ),
            (.turnSubmitted, EventPayloadCodec.encode(submitted) ?? Data(), .turn, "user"),
            (.admissionRequested, Data(), .attempt, "runtime"),
            (.admissionGranted, Data(), .attempt, "runtime"),
            (.runtimeStartRequested, Data(), .attempt, "runtime")
        ]
        let drafts = specs.enumerated().map { index, spec in
            seededDraft(
                conversationID: conversationID,
                turnID: "turn-1",
                attemptID: "attempt-1",
                sequence: index + 1,
                kind: spec.0,
                payload: spec.1,
                scope: spec.2,
                source: spec.3
            )
        }
        do {
            let writer = ConversationSessionActor(
                sessionID: conversationID,
                initialState: initial,
                store: try XCTUnwrap(repository),
                sealing: TestConversationSealing()
            )
            guard case .committed(let state) = writer.submitSync(drafts) else {
                return XCTFail("failed to seed a durable Local Agent runtime dispatch")
            }
            XCTAssertEqual(state.activeAttempt?.phase, .startingRuntime)
            try settleSeededEffect(
                .requestAdmission(
                    sessionID: conversationID,
                    turnID: "turn-1",
                    attemptID: "attempt-1"
                ),
                repository: try XCTUnwrap(repository)
            )
            if claimBeforeRestart {
                let command = EffectCommand.startRuntime(attemptID: "attempt-1")
                let claimed = try XCTUnwrap(try XCTUnwrap(repository).claimOutboxEffect(
                    effectID: ConversationEffectOutboxFactory.stableEffectID(for: command),
                    dispatchToken: "local-agent-crash-boundary",
                    dispatchedAt: "2026-08-11T00:00:00Z"
                ))
                XCTAssertEqual(claimed.state, .dispatching)
            }
        }
        repository = nil

        let reopened = try ConversationRepositoryV2(
            conversationID: conversationID,
            databasePath: dbPath,
            encryption: encryption
        )
        let actor = ConversationSessionActor(
            sessionID: conversationID,
            initialState: initial,
            store: reopened,
            sealing: TestConversationSealing()
        )
        let provider = CountingStreamingProvider(message: "must not run")
        let providerConfig = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "test-key"
        )
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor,
                sessionID: conversationID,
                initialState: initial,
                provider: provider,
                providerConfig: providerConfig
            )
        }

        let restored = await bridge.restoreFromRepository(reopened)

        XCTAssertFalse(restored)
        XCTAssertEqual(provider.invocationCount, 0)
        XCTAssertEqual(actor.latestPublishedState?.activeAttempt?.phase, .interruptedByRelaunch)
        let eventKinds = try reopened.loadEvents().map(\.kind)
        XCTAssertFalse(eventKinds.contains(.runtimeStarted))
        XCTAssertFalse(eventKinds.contains(.localAgentInputDelivered))
        let runtimeCommand = EffectCommand.startRuntime(attemptID: "attempt-1")
        let unresolved = try XCTUnwrap(try reopened.loadUnsettledOutbox().first(where: {
            $0.effectID == ConversationEffectOutboxFactory.stableEffectID(for: runtimeCommand)
        }))
        XCTAssertEqual(unresolved.state, .reconciliationRequired)
        XCTAssertEqual(
            unresolved.reconciliationReason,
            "runtime dispatch may have crossed the process crash boundary"
        )

        var deliveryCount = 0
        let duplicate = await bridge.sendToLocalAgent(
            text: "inspect nginx",
            configuration: configuration,
            deliver: {
                deliveryCount += 1
                return .accepted
            }
        )
        XCTAssertEqual(duplicate, .rejected(reason: .storageUnavailable))
        XCTAssertEqual(deliveryCount, 0)
    }

    private static func makeInitialState(conversationID: String = "c-1") -> ConversationSessionState {
        let target = TargetBinding(
            id: "tb-1", revision: 1, digest: "d1", connectionID: "local",
            connectionKind: "local", remoteIdentity: "user@host", hostKeyFingerprint: nil,
            host: "localhost", user: "user", port: 0, targetWorkingDirectory: "~"
        )
        let session = ConversationSession(
            id: conversationID, title: "测试", createdAt: Date(), updatedAt: Date(),
            targetBinding: target,
            runtimeSelection: AgentRuntimeSelection(kind: .nativeAPI)
        )
        return ConversationSessionState(session: session, lastAppliedSequence: 0)
    }

    private static func makeLocalAgentConfiguration(
        configurationRevision: Int = 1,
        authenticationEvidenceRevision: String = "test-auth-1",
        workingDirectoryMode: AgentProcessWorkingDirectoryMode = .managedWorkspace,
        workingDirectoryReference: String? = nil,
        structuredProtocol: LocalAgentStructuredProtocol? = nil
    ) -> LocalAgentPassthroughConfiguration {
        let launchEnvironment = [
            "PATH=/tools",
            "STACIO_LOCAL_AGENT=codex"
        ].sorted()
        return LocalAgentPassthroughConfiguration(
            configurationID: "test-local-agent",
            configurationRevision: configurationRevision,
            catalogID: "local-agent.codex",
            catalogSetRevision: 1,
            descriptorRevision: 1,
            tool: .codex,
            displayName: "Codex",
            executablePath: "/tools/codex",
            executableIdentityDigest: "test-codex-binary",
            executableReferenceConfirmedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastVerifiedAt: Date(timeIntervalSince1970: 1_700_000_001),
            executionProfileID: structuredProtocol == nil
                ? "test-terminal-profile"
                : "test-managed-profile",
            executionProfileRevision: 1,
            structuredProtocol: structuredProtocol,
            authenticationState: .authenticated,
            authenticationEvidenceRevision: authenticationEvidenceRevision,
            cliAuthenticationScopeDigest: "test-cli-scope",
            cliLoginIdentityDigest: "test-cli-login",
            environmentDigest: LocalAgentConfigurationIntegrity.environmentDigest(launchEnvironment),
            launchArguments: ["--no-alt-screen"],
            launchEnvironment: launchEnvironment,
            executableName: "codex",
            workingDirectoryMode: workingDirectoryMode,
            workingDirectoryReference: workingDirectoryReference,
            supportLevel: .experimental,
            explicitlyEnabled: true
        )
    }

    private static func makeBridge(
        provider: AIAssistantStreamingProviding?,
        store: ConversationSessionStore? = nil,
        conversationID: String = "c-1",
        skipProvider: Bool = false,
        admissionCoordinator: AgentExecutionAdmissionCoordinating? = nil,
        runtimeSettingsSnapshot: AssistantRuntimeSettingsSnapshot? = nil,
        restorePending: Bool = false
    ) async -> (bridge: SessionRuntimeBridge, actor: ConversationSessionActor, store: ConversationSessionStore) {
        let resolvedStore: ConversationSessionStore
        if let store {
            resolvedStore = store
        } else {
            resolvedStore = InMemoryConversationSessionStore()
        }
        let sealing = TestConversationSealing()
        let initialState = makeInitialState(conversationID: conversationID)
        let actor = ConversationSessionActor(
            sessionID: conversationID, initialState: initialState, store: resolvedStore, sealing: sealing
        )
        let config = ProviderRuntimeConfiguration(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model", apiKey: "test-key"
        )
        let bridge = await MainActor.run {
            SessionRuntimeBridge(
                actor: actor, sessionID: conversationID, initialState: initialState,
                provider: provider,
                providerConfig: provider != nil ? config : nil,
                runtimeSettingsProvider: {
                    if let runtimeSettingsSnapshot { return runtimeSettingsSnapshot }
                    return try AssistantRuntimeSettingsSnapshot.resolve(from: nil)
                },
                admissionCoordinator: admissionCoordinator,
                restorePending: restorePending
            )
        }
        return (bridge, actor, resolvedStore)
    }

    private static func runtimeSettings(
        maxParallelAttempts: Int
    ) throws -> AssistantRuntimeSettingsSnapshot {
        let defaults = try AssistantRuntimeSettingsSnapshot.resolve(from: nil)
        var values = defaults.valuesByID
        values["assistant.execution.maxParallelAttempts"] = .int(maxParallelAttempts)
        return AssistantRuntimeSettingsSnapshot(
            registryRevision: defaults.registryRevision,
            valuesByID: values
        )
    }
}

@MainActor
private final class TimelineEntryRecorder {
    var entries: [TimelineSourceEntry] = []
}

private final class CountingStreamingProvider: AIAssistantStreamingProviding {
    private let lock = NSLock()
    private let message: String
    private var storedInvocationCount = 0

    init(message: String) {
        self.message = message
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocationCount
    }

    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        lock.withLock {
            storedInvocationCount += 1
        }
        return AIAssistantResponse(message: message, proposedCommand: nil)
    }
}

private final class UncooperativeStreamingProvider: AIAssistantStreamingProviding {
    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        try? await Task.sleep(nanoseconds: 120_000_000)
        onPartial("迟到增量")
        return AIAssistantResponse(message: "迟到完成", proposedCommand: nil)
    }
}

private final class DelayedCountingStreamingProvider: AIAssistantStreamingProviding {
    private let lock = NSLock()
    private let delayNanoseconds: UInt64
    private var storedInvocationCount = 0
    var onInvocation: ((Int) -> Void)?

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedInvocationCount
    }

    func respondStreaming(
        to request: AIAssistantRequest,
        onPartial: @escaping (String) -> Void
    ) async throws -> AIAssistantResponse {
        let (invocation, callback) = lock.withLock {
            storedInvocationCount += 1
            return (storedInvocationCount, onInvocation)
        }
        callback?(invocation)
        onPartial("增量\(invocation)")
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try Task.checkCancellation()
        return AIAssistantResponse(message: "回答\(invocation)", proposedCommand: nil)
    }
}

private final class CheckpointBlockingConversationStore: ConversationSessionStore {
    private let lock = NSLock()
    private let checkpointGate = DispatchSemaphore(value: 0)
    private let onCheckpointStarted: () -> Void
    private var hasBlockedCheckpoint = false
    private var lastApplied = 0
    private var events: [Int: (eventID: String, payloadHash: String)] = [:]
    private let outboxHarness = TestOutboxHarness()

    init(onCheckpointStarted: @escaping () -> Void) {
        self.onCheckpointStarted = onCheckpointStarted
    }

    func releaseCheckpoint() {
        checkpointGate.signal()
    }

    func load() throws -> ConversationSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ConversationSessionSnapshot(lastAppliedSequence: lastApplied)
    }

    func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome {
        var shouldBlock = false
        lock.lock()
        if hasBlockedCheckpoint == false,
           candidates.contains(where: { $0.kind == .finalAnswerDelta }) {
            hasBlockedCheckpoint = true
            shouldBlock = true
        }
        lock.unlock()

        if shouldBlock {
            onCheckpointStarted()
            checkpointGate.wait()
        }

        lock.lock()
        defer { lock.unlock() }
        guard expectedLastSequence == lastApplied else {
            return .conflict(expected: expectedLastSequence, actual: lastApplied)
        }
        for candidate in candidates {
            events[candidate.candidateSequence] = (candidate.eventID, candidate.payloadHash)
        }
        outboxHarness.append(outbox)
        lastApplied = candidates.last?.candidateSequence ?? expectedLastSequence
        return .committed(lastSequence: lastApplied)
    }

    func existingEventID(at sequence: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events[sequence]?.eventID
    }

    func existingPayloadHash(at sequence: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events[sequence]?.payloadHash
    }


    func loadUnsettledOutbox() throws -> [ConversationOutboxDispatchRecord] {
        outboxHarness.loadUnsettled()
    }

    func claimOutboxEffect(effectID: String, dispatchToken: String, dispatchedAt: String) throws -> ConversationOutboxDispatchRecord? {
        outboxHarness.claim(effectID: effectID, token: dispatchToken, at: dispatchedAt)
    }

    func settleOutbox(itemID: String, dispatchToken: String, outcome: ConversationOutboxSettlementOutcome, settledAt: String) throws -> Bool {
        outboxHarness.settle(itemID: itemID, token: dispatchToken, outcome: outcome, at: settledAt)
    }

    func requireOutboxReconciliation(itemID: String, reason: String) throws -> Bool {
        outboxHarness.requireReconciliation(itemID: itemID, reason: reason)
    }
}

private final class ScriptedConversationSessionStore: ConversationSessionStore {
    private let lock = NSLock()
    private var outcomes: [ConversationCommitOutcome]
    private var lastApplied = 0
    private var events: [Int: (eventID: String, payloadHash: String)] = [:]
    private(set) var commitCount = 0
    private let outboxHarness = TestOutboxHarness()
    private let failingEventKind: ConversationEventKind?

    init(
        outcomes: [ConversationCommitOutcome],
        failingEventKind: ConversationEventKind? = nil
    ) {
        self.outcomes = outcomes
        self.failingEventKind = failingEventKind
    }

    func load() throws -> ConversationSessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ConversationSessionSnapshot(lastAppliedSequence: lastApplied)
    }

    func commit(
        expectedLastSequence: Int,
        candidates: [ConversationEventEnvelope],
        projections: [String: Data],
        outbox: [ConversationEffectOutboxItem]
    ) throws -> ConversationCommitOutcome {
        lock.lock()
        defer { lock.unlock() }
        commitCount += 1
        let outcome: ConversationCommitOutcome
        if let failingEventKind,
           candidates.contains(where: { $0.kind == failingEventKind }) {
            outcome = .storageFailure(reason: "injected failure for \(failingEventKind.rawValue)")
        } else {
            outcome = outcomes.isEmpty
                ? ConversationCommitOutcome.committed(
                    lastSequence: candidates.last?.candidateSequence ?? expectedLastSequence
                )
                : outcomes.removeFirst()
        }
        if case .committed(let sequence) = outcome {
            lastApplied = sequence
            outboxHarness.append(outbox)
            for candidate in candidates {
                events[candidate.candidateSequence] = (candidate.eventID, candidate.payloadHash)
            }
        }
        return outcome
    }

    func existingEventID(at sequence: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events[sequence]?.eventID
    }

    func existingPayloadHash(at sequence: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events[sequence]?.payloadHash
    }


    func loadUnsettledOutbox() throws -> [ConversationOutboxDispatchRecord] {
        outboxHarness.loadUnsettled()
    }

    func claimOutboxEffect(effectID: String, dispatchToken: String, dispatchedAt: String) throws -> ConversationOutboxDispatchRecord? {
        outboxHarness.claim(effectID: effectID, token: dispatchToken, at: dispatchedAt)
    }

    func settleOutbox(itemID: String, dispatchToken: String, outcome: ConversationOutboxSettlementOutcome, settledAt: String) throws -> Bool {
        outboxHarness.settle(itemID: itemID, token: dispatchToken, outcome: outcome, at: settledAt)
    }

    func requireOutboxReconciliation(itemID: String, reason: String) throws -> Bool {
        outboxHarness.requireReconciliation(itemID: itemID, reason: reason)
    }
}

private struct RecoveryToolExecutionEventPayload: Codable {
    let proposalID: String
    let requestID: String
    let state: String
    let summary: String
}

private final class TestOutboxHarness {
    private var records: [String: ConversationOutboxDispatchRecord] = [:]

    func append(_ items: [ConversationEffectOutboxItem]) {
        for item in items where records[item.itemID] == nil {
            records[item.itemID] = ConversationOutboxDispatchRecord(
                itemID: item.itemID,
                effectID: item.effectID,
                operationID: item.operationID,
                idempotencyKey: item.idempotencyKey,
                command: item.command,
                authorityLeaseID: item.authorityLeaseID,
                capabilityGeneration: item.capabilityGeneration,
                permitCommitDecision: item.permitCommitDecision,
                state: .pending,
                dispatchToken: nil,
                dispatchedAt: nil,
                settlementOutcome: nil,
                settledAt: nil,
                reconciliationReason: nil
            )
        }
    }

    func loadUnsettled() -> [ConversationOutboxDispatchRecord] {
        records.values.filter { $0.state != .settled }.sorted { $0.itemID < $1.itemID }
    }

    func claim(effectID: String, token: String, at: String) -> ConversationOutboxDispatchRecord? {
        guard let itemID = records.values
            .filter({ $0.effectID == effectID && $0.state == .pending })
            .map(\.itemID)
            .sorted()
            .first,
              var record = records[itemID] else { return nil }
        record.state = .dispatching
        record.dispatchToken = token
        record.dispatchedAt = at
        records[itemID] = record
        return record
    }

    func settle(
        itemID: String,
        token: String,
        outcome: ConversationOutboxSettlementOutcome,
        at: String
    ) -> Bool {
        guard var record = records[itemID] else { return false }
        if record.state == .settled {
            return record.dispatchToken == token && record.settlementOutcome == outcome.rawValue
        }
        guard record.state == .dispatching, record.dispatchToken == token else { return false }
        record.state = .settled
        record.settlementOutcome = outcome.rawValue
        record.settledAt = at
        records[itemID] = record
        return true
    }

    func requireReconciliation(itemID: String, reason: String) -> Bool {
        guard var record = records[itemID],
              record.state == .pending || record.state == .dispatching else { return false }
        record.state = .reconciliationRequired
        record.reconciliationReason = reason
        records[itemID] = record
        return true
    }
}
