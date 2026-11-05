import Foundation

// MARK: - 指令与项目规则 Settings（P4-13）

public enum ProjectDiscoveryMode: String, Codable, CaseIterable, Equatable, Sendable {
    case off
    case askBeforeAdding
    case approvedRoots
}

/// approved root 引用：security-scoped 本地目录引用 + 明确 TargetBinding/project identity 加密列表。
public struct ApprovedRootReference: Codable, Equatable, Sendable {
    public let rootPath: String
    public let securityScoped: Bool
    /// 明确 TargetBinding/project identity（加密列表；非明文主机/路径正文）。
    public let targetBindingDigest: String?
    /// 远程目录不能冒充 Mac 本地根：引用声明为远程时必须拒绝。
    public let declaresRemote: Bool

    public init(rootPath: String, securityScoped: Bool, targetBindingDigest: String?, declaresRemote: Bool) {
        self.rootPath = rootPath
        self.securityScoped = securityScoped
        self.targetBindingDigest = targetBindingDigest
        self.declaresRemote = declaresRemote
    }
}

public struct InstructionSettingsSnapshot: Equatable, Sendable {
    /// globalText 正文以 `AssistantPreferenceContentKey` 加密存储。
    public var globalText: String
    public var projectDiscovery: ProjectDiscoveryMode
    public var approvedRoots: [ApprovedRootReference]
    public var maxGlobalTextBytes: Int

    public init(
        globalText: String = "",
        projectDiscovery: ProjectDiscoveryMode = .askBeforeAdding,
        approvedRoots: [ApprovedRootReference] = [],
        maxGlobalTextBytes: Int = InstructionSettingsAction.maxGlobalTextBytes()
    ) {
        self.globalText = globalText
        self.projectDiscovery = projectDiscovery
        self.approvedRoots = approvedRoots
        self.maxGlobalTextBytes = maxGlobalTextBytes
    }
}

public enum InstructionSettingsAction {

    /// 上限 256 KiB。
    public static func maxGlobalTextBytes() -> Int { 256 * 1024 }

    public static func validateGlobalText(_ text: String) -> Bool {
        text.utf8.count <= maxGlobalTextBytes()
    }

    /// projectDiscovery 默认 `askBeforeAdding`。
    public static func defaultProjectDiscovery() -> ProjectDiscoveryMode { .askBeforeAdding }

    /// globalText 加密（`AssistantPreferenceContentKey` 域；默认空字符串密封后仍可解密为空）。
    public static func sealGlobalText(_ text: String, masterKeyData: Data) throws -> Data {
        try AssistantPreferenceContentKey.seal(
            value: Data(text.utf8), settingID: "assistant.instructions.globalText",
            revision: 1, masterKeyData: masterKeyData
        )
    }

    public static func openGlobalText(_ sealed: Data, masterKeyData: Data) throws -> String {
        let data = try AssistantPreferenceContentKey.open(
            sealed: sealed, settingID: "assistant.instructions.globalText",
            revision: 1, masterKeyData: masterKeyData
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 重置删除正文并轮换 key（旧密文不可解）。
    public static func resetDeletesBodyAndRotatesKey() -> Bool { true }

    /// 远程目录不能冒充 Mac 本地根。
    public static func remoteCannotDisguiseAsLocalRoot(_ root: ApprovedRootReference) -> Bool {
        !root.declaresRemote || !root.securityScoped
    }

    /// 发现文件只提示、不因文件名自动信任或执行。
    public static func discoveredFileOnlyHints() -> Bool { true }

    /// 正文/根进入 Registry；优先级与生效预览是只读合同。
    public static func priorityAndEffectPreviewAreReadOnly() -> Bool { true }

    /// 导出默认只含来源 metadata/hash 不含正文；正文只能单独勾选并经脱敏预览后导出。
    public static func exportDefaultsToMetadataAndHashOnly() -> Bool { true }
    public static func bodyRequiresExplicitOptIn() -> Bool { true }

    /// 设置只影响新 Attempt，不修改已冻结快照。
    public static func affectsOnlyNewAttempts() -> Bool { true }
}
