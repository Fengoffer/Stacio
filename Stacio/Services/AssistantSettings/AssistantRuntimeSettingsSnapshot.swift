import CryptoKit
import Foundation

public enum AssistantRuntimeSettingsSnapshotError: Error, Equatable {
    case unreadableSetting(String)
    case storeUnavailable
    case registryUnavailable
    case encodingFailed
}

/// Immutable values used by one queued input or Attempt. The snapshot is read
/// from the same durable owner as Settings and is carried with the event stream,
/// so later preference edits cannot change an in-flight operation.
public struct AssistantRuntimeSettingsSnapshot: Codable, Equatable, Hashable, Sendable {
    public let registryRevision: Int
    public let valuesByID: [String: SettingValue]

    public static func resolve(
        from store: AssistantSettingsValueStore?
    ) throws -> AssistantRuntimeSettingsSnapshot {
        let registry: AssistantSettingRegistry
        do {
            registry = try AssistantSettingRegistry.standard()
        } catch {
            throw AssistantRuntimeSettingsSnapshotError.registryUnavailable
        }

        var values: [String: SettingValue] = [:]
        for descriptor in registry.descriptorsByID.values where
            descriptor.id.hasPrefix("assistant.") && descriptor.id.contains("{id}") == false {
            if let store {
                do {
                    values[descriptor.id] = try store.value(for: descriptor.id)
                } catch {
                    throw AssistantRuntimeSettingsSnapshotError.unreadableSetting(descriptor.id)
                }
            } else {
                values[descriptor.id] = descriptor.defaultValue
            }
        }
        return AssistantRuntimeSettingsSnapshot(
            registryRevision: registry.revision,
            valuesByID: values
        )
    }

    public var defaultRuntimeConfigurationID: String? {
        let value = string("assistant.general.defaultRuntime")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public var defaultWorkMode: WorkMode {
        switch string("assistant.general.defaultWorkMode") {
        case "plan": return .plan
        case "answer": return .answerOnly
        default: return .agent
        }
    }

    public var defaultReasoningEffort: AIReasoningEffortPreference {
        AIReasoningEffortPreference(
            rawValue: string("assistant.general.defaultReasoningEffort")
        ) ?? .medium
    }

    public var queueAutoAdvanceEnabled: Bool {
        bool("assistant.general.queueAutoAdvance", fallback: true)
    }

    public var restoreLastConversationEnabled: Bool {
        bool("assistant.general.restoreLastConversation", fallback: true)
    }

    public var sendKeyMode: String {
        string("assistant.general.sendKeyMode", fallback: "return")
    }

    public var localAutoTitleEnabled: Bool {
        bool("assistant.general.localAutoTitle", fallback: true)
    }

    public var defaultTerminalMode: String {
        string("assistant.execution.defaultTerminalMode", fallback: "realTerminal")
    }

    public var maxParallelAttempts: Int {
        min(max(int("assistant.execution.maxParallelAttempts", fallback: 2), 1), 4)
    }

    public var capacityWaitMinutes: Int {
        min(max(int("assistant.execution.capacityWaitMinutes", fallback: 30), 1), 120)
    }

    public var maxToolSteps: Int {
        int("assistant.execution.maxToolSteps", fallback: 40)
    }

    public var maxEffectiveMinutes: Int {
        int("assistant.execution.maxEffectiveMinutes", fallback: 30)
    }

    public var approvalDeadlineMinutes: Int {
        int("assistant.execution.approvalDeadlineMinutes", fallback: 10)
    }

    public var maxModelInvocations: Int {
        int("assistant.usage.maxModelInvocations", fallback: 40)
    }

    public var globalInstructions: String {
        string("assistant.instructions.globalText")
    }

    public var terminalOutputMode: String {
        string("assistant.context.terminalOutputMode", fallback: "boundedHeadTail")
    }

    public var automaticContextCompressionEnabled: Bool {
        bool("assistant.context.autoCompression", fallback: true)
    }

    public var historyRetentionDays: Int {
        min(max(int("assistant.history.retention", fallback: 30), 1), 3_650)
    }

    public var telemetryEnabled: Bool {
        bool("assistant.privacy.telemetryEnabled", fallback: false)
    }

    public var terminalRecordingScope: String {
        string("assistant.privacy.terminalRecordingScope", fallback: "bounded")
    }

    public var enabledToolIDs: [String] {
        stringArray("assistant.tools.enabledToolIDs")
    }

    public var instructionDigest: String? {
        guard globalInstructions.isEmpty == false else { return nil }
        let digest = SHA256.hash(data: Data(globalInstructions.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let value = String(data: try encoder.encode(self), encoding: .utf8) else {
            throw AssistantRuntimeSettingsSnapshotError.encodingFailed
        }
        return value
    }

    public func encodedValues(for ids: Set<String>) throws -> String {
        let subset = AssistantRuntimeSettingsSnapshot(
            registryRevision: registryRevision,
            valuesByID: valuesByID.filter { ids.contains($0.key) }
        )
        return try subset.encoded()
    }

    private func string(_ id: String, fallback: String = "") -> String {
        guard case .string(let value)? = valuesByID[id] else { return fallback }
        return value
    }

    private func int(_ id: String, fallback: Int) -> Int {
        guard case .int(let value)? = valuesByID[id] else { return fallback }
        return value
    }

    private func bool(_ id: String, fallback: Bool) -> Bool {
        guard case .bool(let value)? = valuesByID[id] else { return fallback }
        return value
    }

    private func stringArray(_ id: String) -> [String] {
        guard case .stringArray(let value)? = valuesByID[id] else { return [] }
        return value
    }
}
