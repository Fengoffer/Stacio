import Foundation

public enum AssistantSettingsMutationError: Error, Equatable {
    case unknownSetting(String)
    case unsupportedWritePolicy(String)
    case actionUnavailable(String)
    case persistenceFailed(String)
    case historyPruningUnavailable
    case historyPruningFailed
}

/// The single mutation owner used by the visible troubleshooting-assistant
/// settings. Ordinary values write through the registry-validated store;
/// action-only privacy/history values keep their durable audit contract.
public final class AssistantSettingsMutationCoordinator {
    private let valueStore: AssistantSettingsValueStore
    private let actionCoordinator: AssistantSettingsActionCoordinator
    private let historyPruner: AIAssistantConversationHistoryPruning?
    private let now: () -> Date

    public init(
        valueStore: AssistantSettingsValueStore,
        settingsDatabasePath: String,
        controlDatabasePath: String,
        historyPruner: AIAssistantConversationHistoryPruning? = nil,
        now: @escaping () -> Date = Date.init
    ) throws {
        let actionRegistry = try AssistantSettingsActionRegistry.standard()
        let backend = try AssistantSettingsStoreBackend(databasePath: settingsDatabasePath)
        let eventStore = AssistantSettingsEventStore(backend: backend)
        let control = try AgentConversationV2ControlCoordinator(databasePath: controlDatabasePath)
        let actionCoordinator = AssistantSettingsActionCoordinator(
            registry: actionRegistry,
            control: control,
            eventStore: eventStore
        )

        self.valueStore = valueStore
        self.actionCoordinator = actionCoordinator
        self.historyPruner = historyPruner
        self.now = now
        try Self.registerValueOwners(
            in: actionCoordinator,
            valueStore: valueStore,
            eventStore: eventStore
        )
    }

    public static func live(
        valueStore: AssistantSettingsValueStore,
        historyPruner: AIAssistantConversationHistoryPruning? = CoreBridgeAIAssistantConversationHistoryStore.defaultStore()
    ) throws -> AssistantSettingsMutationCoordinator {
        let paths = try StacioPaths()
        return try AssistantSettingsMutationCoordinator(
            valueStore: valueStore,
            settingsDatabasePath: paths.applicationSupportDirectory
                .appendingPathComponent("assistant-settings.sqlite3").path,
            controlDatabasePath: paths.applicationSupportDirectory
                .appendingPathComponent("agent-control.sqlite3").path,
            historyPruner: historyPruner
        )
    }

    /// Registers the real Local Agent business owner on this coordinator's
    /// single Action graph. The UI never receives a second, parallel action
    /// router, so availability and audit events remain consistent.
    public func registerLocalAgentOwners(
        _ localAgentCoordinator: LocalAgentSettingsCoordinator,
        configurationDeleteRouter: ConfigurationDeleteActionRouter
    ) throws {
        try configurationDeleteRouter.registerActionOwner(in: actionCoordinator)
        try localAgentCoordinator.registerOwners(
            in: actionCoordinator,
            configurationDeleteRouter: configurationDeleteRouter
        )
    }

    public func isActionAvailable(_ actionID: String) -> Bool {
        actionCoordinator.isActionAvailable(actionID)
    }

    public func performAction(
        actionID: String,
        parameters: [String: SettingValue],
        completion: @escaping (
            Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>
        ) -> Void
    ) {
        actionCoordinator.perform(
            AssistantSettingsActionRequest(
                actionID: actionID,
                operationID: "assistant-settings-\(UUID().uuidString.lowercased())",
                parameters: parameters
            ),
            completion: completion
        )
    }

    public func write(
        settingID: String,
        value: SettingValue,
        completion: @escaping (Result<Void, AssistantSettingsMutationError>) -> Void
    ) {
        guard let descriptor = valueStore.descriptor(for: settingID) else {
            completion(.failure(.unknownSetting(settingID)))
            return
        }

        switch descriptor.writeControlPolicy {
        case .userWritable:
            do {
                try valueStore.write(
                    id: settingID,
                    value: value,
                    scope: descriptor.scope.rawValue,
                    migrationKey: descriptor.migrationKey
                )
                publishChange(settingID: settingID)
                completion(.success(()))
            } catch {
                completion(.failure(.persistenceFailed(settingID)))
            }

        case .actionOnly:
            guard let actionID = AssistantSettingsActionBinding.actionID(for: settingID),
                  actionCoordinator.hasBusinessOwner(for: actionID)
            else {
                completion(.failure(.actionUnavailable(settingID)))
                return
            }
            actionCoordinator.perform(AssistantSettingsActionRequest(
                actionID: actionID,
                operationID: "assistant-settings-\(UUID().uuidString.lowercased())",
                parameters: [
                    "settingID": .string(settingID),
                    "value": value
                ]
            )) { [weak self] result in
                switch result {
                case .success(.succeeded):
                    guard let self else {
                        completion(.failure(.persistenceFailed(settingID)))
                        return
                    }
                    if settingID == "assistant.history.retention" {
                        guard case .int(let retentionDays) = value else {
                            completion(.failure(.persistenceFailed(settingID)))
                            return
                        }
                        guard let historyPruner = self.historyPruner else {
                            completion(.failure(.historyPruningUnavailable))
                            return
                        }
                        let referenceDate = self.now()
                        let cutoff = Calendar(identifier: .gregorian).date(
                            byAdding: .day,
                            value: -retentionDays,
                            to: referenceDate
                        ) ?? referenceDate
                        do {
                            try historyPruner.pruneConversationHistory(olderThan: cutoff)
                        } catch {
                            // The setting is already durable; publish it so every
                            // reader sees the real state even when cleanup must be retried.
                            self.publishChange(settingID: settingID)
                            completion(.failure(.historyPruningFailed))
                            return
                        }
                    }
                    self.publishChange(settingID: settingID)
                    completion(.success(()))
                case .success(.cancelled),
                     .success(.failed),
                     .success(.reconciliationRequired),
                     .failure:
                    completion(.failure(.persistenceFailed(settingID)))
                }
            }

        case .readOnlyProjection:
            completion(.failure(.unsupportedWritePolicy(settingID)))
        }
    }

    private func publishChange(settingID: String) {
        NotificationCenter.default.post(
            name: .stacioAssistantSettingsDidChange,
            object: valueStore,
            userInfo: ["settingID": settingID]
        )
    }

    private static func registerValueOwners(
        in coordinator: AssistantSettingsActionCoordinator,
        valueStore: AssistantSettingsValueStore,
        eventStore: AssistantSettingsEventStore
    ) throws {
        let owner: AssistantSettingsActionOwner = { request, completion in
            guard case .string(let settingID) = request.parameters["settingID"],
                  let value = request.parameters["value"],
                  let descriptor = valueStore.descriptor(for: settingID),
                  AssistantSettingsActionBinding.actionID(for: settingID) == request.actionID
            else {
                completion(.failed(reasonCode: "invalid_setting_request"))
                return
            }

            do {
                let revision = try valueStore.writeActionValue(
                    id: settingID,
                    value: value,
                    actionID: request.actionID,
                    scope: descriptor.scope.rawValue,
                    migrationKey: descriptor.migrationKey
                )
                do {
                    try eventStore.mutationCommittedAndSettled(operationID: request.operationID)
                } catch {
                    completion(.reconciliationRequired(referenceID: request.operationID))
                    return
                }
                completion(.succeeded(proofDigest: "setting:\(settingID):revision:\(revision)"))
            } catch {
                completion(.failed(reasonCode: "setting_write_failed"))
            }
        }

        try coordinator.registerOwner(
            for: ["history.changeRetention", "privacy.changeTelemetryConsent"],
            owner: owner
        )
    }
}
