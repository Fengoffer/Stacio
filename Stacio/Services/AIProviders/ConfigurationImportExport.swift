import Foundation

// MARK: - 配置导入导出（P4-9a）

/// 导出可见性：白名单 `exportable|explicitPreview`；`never` 永不进入 manifest。
public enum ConfigurationExportVisibility: String, Codable, Equatable, Sendable {
    case exportable
    case explicitPreview
    case never
}

public struct ConfigurationExportEntry: Equatable, Sendable {
    public let configurationID: String
    public let field: String
    public let visibility: ConfigurationExportVisibility
    public let value: String?

    public init(configurationID: String, field: String, visibility: ConfigurationExportVisibility, value: String?) {
        self.configurationID = configurationID
        self.field = field
        self.visibility = visibility
        self.value = value
    }
}

public struct ConfigurationExportManifest: Equatable, Sendable {
    public let entries: [ConfigurationExportEntry]

    public init(entries: [ConfigurationExportEntry]) {
        self.entries = entries
    }
}

public struct ExportPlan: Equatable, Sendable {
    /// 脱敏预览（先预览再写文件）。
    public let redactedPreview: [String: String]
    public let manifest: ConfigurationExportManifest

    public init(redactedPreview: [String: String], manifest: ConfigurationExportManifest) {
        self.redactedPreview = redactedPreview
        self.manifest = manifest
    }
}

/// import dry-run 差异预览。
public struct ImportDiffPreview: Equatable, Sendable {
    public let added: [String]
    public let changed: [String]
    public let unchanged: [String]
    public let unknownFields: [String]

    public init(added: [String], changed: [String], unchanged: [String], unknownFields: [String]) {
        self.added = added
        self.changed = changed
        self.unchanged = unchanged
        self.unknownFields = unknownFields
    }

    public var isEmpty: Bool {
        added.isEmpty && changed.isEmpty && unknownFields.isEmpty
    }
}

/// 逐配置提交报告：单项失败不使其他项伪报成功。
public struct ImportCommitReport: Equatable, Sendable {
    public let succeeded: [String]
    public let failed: [String]

    public init(succeeded: [String], failed: [String]) {
        self.succeeded = succeeded
        self.failed = failed
    }

    public var allSucceeded: Bool { failed.isEmpty }
}

public enum ConfigurationImportExport {

    /// 永不进入 manifest 的字段（credential/Keychain ref/OAuth/代理密码/secret header/env 值）。
    public static func neverExported(field: String) -> Bool {
        let lower = field.lowercased()
        return lower.contains("key") || lower.contains("secret") || lower.contains("token")
            || lower.contains("cookie") || lower.contains("oauth") || lower.contains("proxy")
            || lower.contains("password") || lower.contains("header") || lower.contains("env")
            || lower == "credentialreference" || lower.contains("keychain")
    }

    /// 白名单判定：`exportable|explicitPreview` 且非 never 字段、非 secret 值。
    public static func isExportable(visibility: ConfigurationExportVisibility, field: String, value: String?) -> Bool {
        guard visibility != .never, !neverExported(field: field) else { return false }
        if visibility == .explicitPreview, value == nil { return false }
        return true
    }

    /// export：先脱敏预览再写文件（预览值脱敏、manifest 才含真实值）。
    public static func exportPlan(entries: [ConfigurationExportEntry]) -> ExportPlan {
        let exportable = entries.filter { isExportable(visibility: $0.visibility, field: $0.field, value: $0.value) }
        var redacted: [String: String] = [:]
        for entry in exportable {
            redacted["\(entry.configurationID).\(entry.field)"] = entry.visibility == .explicitPreview ? "[preview]" : (entry.value ?? "")
        }
        return ExportPlan(
            redactedPreview: redacted,
            manifest: ConfigurationExportManifest(entries: exportable)
        )
    }

    /// import：先 dry-run 差异预览。
    public static func dryRun(imported: [String: String], current: [String: String]) -> ImportDiffPreview {
        var added: [String] = []
        var changed: [String] = []
        var unchanged: [String] = []
        for (field, value) in imported {
            if let existing = current[field] {
                if existing == value {
                    unchanged.append(field)
                } else {
                    changed.append(field)
                }
            } else {
                added.append(field)
            }
        }
        return ImportDiffPreview(
            added: added.sorted(), changed: changed.sorted(), unchanged: unchanged.sorted(),
            unknownFields: []
        )
    }

    /// 未知字段保留报告不生效。
    public static func unknownFields(imported: [String], known: Set<String>) -> [String] {
        imported.filter { !known.contains($0) }.sorted()
    }

    /// 导入项统一 NeedsVerification/NeedsEndpoint（不继承导出方状态）。
    public static func importedProjectedState(hasEndpoint: Bool) -> ProviderConfigurationState {
        hasEndpoint ? .needsVerification : .needsEndpoint
    }

    /// 永不携带隐藏授权（导入不含任何 capability/授权标记）。
    public static func carriesHiddenAuthorization() -> Bool { false }

    /// 逐配置提交：每个导入 Configuration 分别经 configurationSaveDraft 提交；
    /// 单项失败不使其他项伪报成功。
    public static func commitReport(results: [String: Bool]) -> ImportCommitReport {
        ImportCommitReport(
            succeeded: results.filter { $0.value }.map(\.key).sorted(),
            failed: results.filter { !$0.value }.map(\.key).sorted()
        )
    }
}
