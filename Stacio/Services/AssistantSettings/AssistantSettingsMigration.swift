import Foundation

// MARK: - AssistantSettingsMigration（P4-2，逐 ID alias，禁止显示名模糊匹配）

/// 迁移规则：逐 ID alias（旧 ID → 当前 ID）。禁止按显示名模糊匹配——
/// 迁移表是唯一合法映射，显示名变化不影响 ID 解析。
public enum AssistantSettingsMigration {
    /// alias 表（migrationKey → 当前稳定 ID）。
    public static let aliasesByMigrationKey: [String: String] = [
        "general.defaultRuntime.v1": "assistant.general.defaultRuntime",
        "general.resumeLastSession.v1": "assistant.general.restoreLastConversation",
        "general.sendShortcut.v1": "assistant.general.sendKeyMode",
        "general.autoTitle.v1": "assistant.general.localAutoTitle",
        "execution.maxParallelSessions.v1": "assistant.execution.maxParallelAttempts",
        "execution.maxTurnDurationMinutes.v1": "assistant.execution.maxEffectiveMinutes",
        "execution.maxToolSteps.v1": "assistant.execution.maxToolSteps",
        "provider.configurationOrder.v1": "assistant.general.configurationOrder",
        "context.globalText.v1": "assistant.instructions.globalText",
        "context.terminalOutputPolicy.v1": "assistant.context.terminalOutputMode",
        "memory.retentionPeriod.v1": "assistant.history.retention",
        "memory.projectMemory.v1": "assistant.memory.projectEnabled",
        "privacy.telemetry.v1": "assistant.privacy.telemetryEnabled",
        "appearance.sessionDensity.v1": "assistant.appearance.timelineDensity",
        "appearance.reduceMotion.v1": "assistant.appearance.motionMode"
    ]

    public enum MigrationError: Error, Equatable {
        /// 未知迁移键（不能通过显示名或猜测解析）。
        case unknownMigrationKey(String)
    }

    /// 按 migrationKey 解析当前 ID（唯一合法映射；显示名不参与）。
    /// 当前版本约定：`migrationKey == "<id>.v1"`（逐 ID alias）；
    /// 历史迁移键经 `aliasesByMigrationKey` 表解析。
    public static func currentID(forMigrationKey key: String) throws -> String {
        if let id = aliasesByMigrationKey[key] {
            return id
        }
        if key.hasSuffix(".v1") {
            return String(key.dropLast(3))
        }
        throw MigrationError.unknownMigrationKey(key)
    }

    /// 校验 descriptor 的 migrationKey 可追溯且唯一命中自身：
    /// 未知迁移键 → 构建失败；显示名/任意文本 → 失败（禁止显示名模糊匹配）。
    public static func validate(_ registry: AssistantSettingRegistry) throws {
        var seen: Set<String> = []
        for (id, descriptor) in registry.descriptorsByID {
            if descriptor.migrationKey.isEmpty { continue }
            guard !seen.contains(descriptor.migrationKey) else {
                throw MigrationError.unknownMigrationKey(descriptor.migrationKey)
            }
            seen.insert(descriptor.migrationKey)
            let resolved = try currentID(forMigrationKey: descriptor.migrationKey)
            guard resolved == id else {
                throw MigrationError.unknownMigrationKey(descriptor.migrationKey)
            }
        }
    }
}
