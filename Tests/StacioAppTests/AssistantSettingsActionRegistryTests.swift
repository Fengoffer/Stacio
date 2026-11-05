import XCTest
import Foundation
@testable import StacioApp

/// P4-2：Settings Action Registry（48 穷尽分区、唯一命中、复合 Action proof 链）与
/// Coordinator（Permit gate、safetySettlement/controlIndependent 能力边界、maintenanceFence）。
final class AssistantSettingsActionRegistryTests: XCTestCase {
    private final class StaticControlState: AssistantSettingsControlStateProviding {
        var state: AgentConversationV2ControlState
        init(_ state: AgentConversationV2ControlState) { self.state = state }
        func controlState() throws -> AgentConversationV2ControlState { state }
    }

    private func makeRegistry() throws -> AssistantSettingsActionRegistry {
        try AssistantSettingsActionRegistry.standard()
    }

    // MARK: - 唯一命中与穷尽分区

    func testFortyEightActionsExhaustivePartitions() throws {
        let registry = try makeRegistry()
        XCTAssertEqual(registry.actionsByID.count, 48, "48 个 Action")
        try registry.validatePartitionCounts()
        XCTAssertEqual(registry.partitionCounts()[.enabledEphemeral], 1)
        XCTAssertEqual(registry.partitionCounts()[.enabledPermit], 25)
        XCTAssertEqual(registry.partitionCounts()[.safetySettlement], 7)
        XCTAssertEqual(registry.partitionCounts()[.controlIndependentUserAction], 9)
        XCTAssertEqual(registry.partitionCounts()[.maintenanceFence], 6)
    }

    func testUnknownOrMultipleHitFailsBuild() throws {
        // 多重命中（重复 ID）→ 构建失败
        let dup = try makeRegistry().actionsByID.values.first!
        XCTAssertThrowsError(try AssistantSettingsActionRegistry.build(actions: [dup, dup])) { error in
            XCTAssertEqual(error as? AssistantSettingsActionRegistryError, .duplicateID(dup.id))
        }
        // 未知 action → coordinator 拒绝
        let registry = try makeRegistry()
        XCTAssertNil(registry.action(for: "does.not.exist"))
    }

    func testCoordinatorRejectsOwnerForUnknownAction() throws {
        let (coordinator, _, _) = try makeCoordinator()
        XCTAssertThrowsError(try coordinator.registerOwner(for: "typo.action") { _, completion in
            completion(.succeeded(proofDigest: nil))
        }) { error in
            XCTAssertEqual(error as? AssistantSettingsActionError, .unknownAction("typo.action"))
        }
    }

    func testEveryActionHasRequiredFields() throws {
        let registry = try makeRegistry()
        for (id, action) in registry.actionsByID {
            XCTAssertFalse(id.isEmpty)
            XCTAssertFalse(action.parameterSchema.isEmpty, "\(id): parameterSchema 必含")
            XCTAssertFalse(action.resultSchema.isEmpty, "\(id): resultSchema 必含")
            XCTAssertTrue(
                ["actionRequested", "actionCancelled", "actionFailed",
                 "actionReconciliationRequired", "actionSettled"].contains(action.auditEventKind),
                "\(id): auditEventKind 必须映射到关闭 kind"
            )
            if action.controlPolicy == .enabledPermit {
                XCTAssertNotNil(action.requiredOperationKind, "\(id): enabledPermit 必须绑定 operation kind")
            }
        }
    }

    // MARK: - 复合 Action

    func testCompositeActionStepsHaveIndependentIDsAndProofChain() throws {
        let registry = try makeRegistry()
        let steps = try XCTUnwrap(registry.compositeSteps["provider.saveCredentialAndFetchModels"])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].subActionID, "provider.saveCredentialAndFetchModels")
        XCTAssertEqual(steps[1].subActionID, "provider.fetchModels")
        XCTAssertEqual(
            steps[1].requiresProofOf,
            "provider.saveCredentialAndFetchModels",
            "前一步 proof 是后一步前置"
        )

        // 每个子 operation 独立稳定 ID（各自命中 registry 一行）
        for step in steps {
            XCTAssertNotNil(registry.action(for: step.subActionID), "子 operation 独立 ID 必须命中")
        }

        // proof 链校验：缺 saveApiKey proof → 拒绝
        let executor = CompositeActionExecutor(registry: registry)
        let missing = executor.validatePrerequisites(
            parentID: "provider.saveCredentialAndFetchModels",
            proofs: ["provider.fetchModels": .proof("fetch-proof")]
        )
        guard case .failure(let error) = missing else {
            return XCTFail("缺前置 proof 必须失败")
        }
        XCTAssertEqual(
            error,
            .missingPrerequisiteProof(subActionID: "provider.saveCredentialAndFetchModels")
        )

        let explicitNone = executor.validatePrerequisites(
            parentID: "provider.saveCredentialAndFetchModels",
            proofs: [
                "provider.saveCredentialAndFetchModels": ActionProof.none,
                "provider.fetchModels": .proof("fetch-proof")
            ]
        )
        guard case .failure(let explicitNoneError) = explicitNone else {
            return XCTFail("显式 none 不能作为前置 proof")
        }
        XCTAssertEqual(
            explicitNoneError,
            .missingPrerequisiteProof(subActionID: "provider.saveCredentialAndFetchModels")
        )

        // 完整 proof 链 → 成功（不是共享成功布尔：每个子 operation 独立 proof）
        let complete = executor.validatePrerequisites(
            parentID: "provider.saveCredentialAndFetchModels",
            proofs: [
                "provider.saveCredentialAndFetchModels": .proof("save-proof"),
                "provider.fetchModels": .proof("fetch-proof")
            ]
        )
        guard case .success = complete else {
            return XCTFail("完整 proof 链必须成功，实际 \(complete)")
        }
    }

    // MARK: - Coordinator gates

    func testEnabledPermitOnlyInEnabled() {
        XCTAssertTrue(AssistantSettingsActionPolicy.canIssuePermit(controlState: .enabled))
        XCTAssertFalse(AssistantSettingsActionPolicy.canIssuePermit(controlState: .draining), "drain 后无新 authorization")
        XCTAssertFalse(AssistantSettingsActionPolicy.canIssuePermit(controlState: .disabled))
        XCTAssertTrue(
            AssistantSettingsActionPolicy.drainBlocksNewAuthorization(controlState: .draining),
            "draining 阻止新 authorization（存量完成）"
        )
    }

    func testSafetySettlementScope() {
        XCTAssertTrue(AssistantSettingsActionPolicy.safetySettlementAllows(.disableAccess))
        XCTAssertTrue(AssistantSettingsActionPolicy.safetySettlementAllows(.revokeCredential))
        XCTAssertTrue(AssistantSettingsActionPolicy.safetySettlementAllows(.isolateTarget))
        XCTAssertTrue(AssistantSettingsActionPolicy.safetySettlementAllows(.collectEvidence))
        XCTAssertFalse(AssistantSettingsActionPolicy.safetySettlementAllows(.issuePermit))
        XCTAssertFalse(AssistantSettingsActionPolicy.safetySettlementAllows(.readCredential))
        XCTAssertFalse(AssistantSettingsActionPolicy.safetySettlementAllows(.targetCapability))
        // 三态可用
        XCTAssertTrue(AssistantSettingsActionPolicy.usableIn(state: .draining, policy: .safetySettlement))
        XCTAssertTrue(AssistantSettingsActionPolicy.usableIn(state: .disabled, policy: .safetySettlement))
    }

    func testControlIndependentGetsNoCapabilities() {
        XCTAssertFalse(AssistantSettingsActionPolicy.controlIndependentAllows(.issuePermit))
        XCTAssertFalse(AssistantSettingsActionPolicy.controlIndependentAllows(.readCredential))
        XCTAssertFalse(AssistantSettingsActionPolicy.controlIndependentAllows(.targetCapability))
        // 三态可用
        XCTAssertTrue(AssistantSettingsActionPolicy.usableIn(state: .draining, policy: .controlIndependentUserAction))
        XCTAssertTrue(AssistantSettingsActionPolicy.usableIn(state: .disabled, policy: .controlIndependentUserAction))
    }

    func testMaintenanceFenceRules() {
        // delete-all 仅 disabled
        XCTAssertFalse(
            AssistantSettingsActionPolicy.maintenanceFenceAllows(
                actionID: "history.deleteAllV2", controlState: .enabled, fenceEngaged: false
            ),
            "delete-all 仅 disabled"
        )
        XCTAssertTrue(
            AssistantSettingsActionPolicy.maintenanceFenceAllows(
                actionID: "history.deleteAllV2", controlState: .disabled, fenceEngaged: false
            )
        )
        // 其余按 fence 状态
        XCTAssertFalse(
            AssistantSettingsActionPolicy.maintenanceFenceAllows(
                actionID: "assistant.resetCaches", controlState: .enabled, fenceEngaged: true
            ),
            "fence engaged 阻止 maintenance action"
        )
        XCTAssertTrue(
            AssistantSettingsActionPolicy.maintenanceFenceAllows(
                actionID: "assistant.resetCaches", controlState: .enabled, fenceEngaged: false
            )
        )
    }

    func testEphemeralOnlyInEnabled() {
        XCTAssertTrue(AssistantSettingsActionPolicy.usableIn(state: .enabled, policy: .enabledEphemeral))
        XCTAssertFalse(AssistantSettingsActionPolicy.usableIn(state: .draining, policy: .enabledEphemeral))
        XCTAssertFalse(AssistantSettingsActionPolicy.usableIn(state: .disabled, policy: .enabledEphemeral))
    }

    // MARK: - Typed owner dispatch and settlement

    func testMissingBusinessOwnerFailsClosedAndNeverSettles() throws {
        let (coordinator, eventStore, _) = try makeCoordinator()
        let request = AssistantSettingsActionRequest(
            actionID: "provider.fetchModels",
            operationID: "settings-op-missing-owner"
        )
        var response: Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>?
        coordinator.perform(request) { response = $0 }

        XCTAssertEqual(response, .failure(.missingOwner("provider.fetchModels")))
        XCTAssertEqual(
            try eventStore.events(operationID: request.operationID),
            ["actionRequested", "actionFailed"]
        )
    }

    func testBusinessSuccessIsSettledOnlyAfterTypedOwnerResult() throws {
        let (coordinator, eventStore, owners) = try makeCoordinator()
        var captured: AssistantSettingsActionRequest?
        try owners.register(actionIDs: ["provider.fetchModels"]) { request, complete in
            captured = request
            complete(.succeeded(proofDigest: "sha256:verified"))
        }
        let request = AssistantSettingsActionRequest(
            actionID: "provider.fetchModels",
            operationID: "settings-op-success",
            parameters: ["configurationID": .string("provider-1")]
        )
        var response: Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>?
        coordinator.perform(request) { response = $0 }

        XCTAssertEqual(captured, request)
        XCTAssertEqual(response, .success(.succeeded(proofDigest: "sha256:verified")))
        XCTAssertEqual(
            try eventStore.events(operationID: request.operationID),
            ["actionRequested", "actionSettled"]
        )
    }

    func testOwnerFailureAndDuplicateCallbackCannotProduceFalseSuccess() throws {
        let (coordinator, eventStore, owners) = try makeCoordinator()
        try owners.register(actionIDs: ["provider.testConnection"]) { _, complete in
            complete(.failed(reasonCode: "upstreamUnauthorized"))
            complete(.succeeded(proofDigest: "late-invalid-success"))
        }
        let request = AssistantSettingsActionRequest(
            actionID: "provider.testConnection",
            operationID: "settings-op-failed"
        )
        var responses: [Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>] = []
        coordinator.perform(request) { responses.append($0) }

        XCTAssertEqual(responses, [.success(.failed(reasonCode: "upstreamUnauthorized"))])
        XCTAssertEqual(
            try eventStore.events(operationID: request.operationID),
            ["actionRequested", "actionFailed"]
        )
    }

    func testControlStateIsReadByCoordinatorInsteadOfTrustedFromCaller() throws {
        let (coordinator, eventStore, owners) = try makeCoordinator(state: .draining)
        try owners.register(actionIDs: ["provider.fetchModels"]) { _, complete in
            complete(.succeeded(proofDigest: nil))
        }
        let request = AssistantSettingsActionRequest(
            actionID: "provider.fetchModels",
            operationID: "settings-op-draining"
        )
        var response: Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>?
        coordinator.perform(request) { response = $0 }

        XCTAssertEqual(response, .failure(.controlStateBlocks("provider.fetchModels")))
        XCTAssertEqual(try eventStore.events(operationID: request.operationID), [])
    }

    func testActionBackedSettingOwnerPersistsValueAndAuditBeforeSettlement() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-action-value-\(UUID().uuidString).sqlite3")
        let sidecar = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-action-value-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(at: sidecar)
        }

        let registry = try AssistantSettingRegistry.standard()
        let valueStore = try AssistantSettingsValueStore(
            registry: registry,
            backend: nil,
            fileURL: sidecar,
            masterKeyProvider: nil
        )
        let backend = try AssistantSettingsStoreBackend(databasePath: path.path)
        let eventStore = AssistantSettingsEventStore(backend: backend)
        let owners = AssistantSettingsActionOwnerRegistry()
        let coordinator = AssistantSettingsActionCoordinator(
            registry: try makeRegistry(),
            control: StaticControlState(.enabled),
            eventStore: eventStore,
            owners: owners
        )
        try coordinator.registerOwner(for: "history.changeRetention") { request, completion in
            guard case .string(let settingID) = request.parameters["settingID"],
                  let value = request.parameters["value"],
                  let descriptor = valueStore.descriptor(for: settingID),
                  AssistantSettingsActionBinding.actionID(for: settingID) == request.actionID
            else {
                completion(.failed(reasonCode: "invalid_setting_request"))
                return
            }
            do {
                _ = try valueStore.writeActionValue(
                    id: settingID,
                    value: value,
                    actionID: request.actionID,
                    scope: descriptor.scope.rawValue,
                    migrationKey: descriptor.migrationKey
                )
                try eventStore.mutationCommittedAndSettled(operationID: request.operationID)
                completion(.succeeded(proofDigest: "verified"))
            } catch {
                completion(.failed(reasonCode: "write_failed"))
            }
        }

        let request = AssistantSettingsActionRequest(
            actionID: "history.changeRetention",
            operationID: "settings-action-value",
            parameters: [
                "settingID": .string("assistant.history.retention"),
                "value": .int(45)
            ]
        )
        var result: Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>?
        coordinator.perform(request) { result = $0 }

        XCTAssertEqual(result, .success(.succeeded(proofDigest: "verified")))
        XCTAssertEqual(try valueStore.value(for: "assistant.history.retention"), .int(45))
        XCTAssertEqual(
            try eventStore.events(operationID: request.operationID),
            ["actionRequested", "settingMutationCommitted", "settingMutationSettled", "actionSettled"]
        )
    }

    private func makeCoordinator(
        state: AgentConversationV2ControlState = .enabled
    ) throws -> (
        AssistantSettingsActionCoordinator,
        AssistantSettingsEventStore,
        AssistantSettingsActionOwnerRegistry
    ) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-action-owner-\(UUID().uuidString).sqlite3").path
        let backend = try AssistantSettingsStoreBackend(databasePath: path)
        let eventStore = AssistantSettingsEventStore(backend: backend)
        let owners = AssistantSettingsActionOwnerRegistry()
        let coordinator = AssistantSettingsActionCoordinator(
            registry: try makeRegistry(),
            control: StaticControlState(state),
            eventStore: eventStore,
            owners: owners
        )
        return (coordinator, eventStore, owners)
    }
}
