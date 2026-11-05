import Foundation

// MARK: - Stacio Tool Catalog（P4-11，§20.1）

public enum StacioBuiltinToolID {
    /// Existing Native API providers return structured shell-command proposals.
    /// This stable ID makes that capability explicit instead of treating every
    /// arbitrary model string as an undeclared tool.
    public static let terminalCommand = "terminal.command"
}

/// Stacio 工具 descriptor：固定 tool ID、schema revision、TargetBinding 适用性、
/// 读写/提权/网络风险、planningSafeReadOnly 资格、所需 lease、输入/输出上限、审计策略。
public struct StacioToolDescriptor: Codable, Equatable, Sendable {
    public let toolID: String
    public let schemaRevision: Int
    public let applicableTargetBindingKinds: [String]
    public let writeRisk: Bool
    public let escalationRisk: Bool
    public let networkRisk: Bool
    /// `planningSafeReadOnly` 资格：只有操作可验证只读、幂等且无持久副作用时
    /// 才可由签名 Catalog 声明（用户不能自行勾选）。
    public let planningSafeReadOnly: Bool
    public let requiredLease: String?
    public let maxInputBytes: Int
    public let maxOutputBytes: Int
    public let auditPolicy: String
    /// executable/argv/schema 不可由设置页编辑（防止冒充内置工具）。
    public let executable: String?
    public let argv: [String]?

    public init(
        toolID: String, schemaRevision: Int, applicableTargetBindingKinds: [String],
        writeRisk: Bool, escalationRisk: Bool, networkRisk: Bool,
        planningSafeReadOnly: Bool, requiredLease: String?,
        maxInputBytes: Int, maxOutputBytes: Int, auditPolicy: String,
        executable: String? = nil, argv: [String]? = nil
    ) {
        self.toolID = toolID
        self.schemaRevision = schemaRevision
        self.applicableTargetBindingKinds = applicableTargetBindingKinds
        self.writeRisk = writeRisk
        self.escalationRisk = escalationRisk
        self.networkRisk = networkRisk
        self.planningSafeReadOnly = planningSafeReadOnly
        self.requiredLease = requiredLease
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
        self.auditPolicy = auditPolicy
        self.executable = executable
        self.argv = argv
    }

    /// planningSafeReadOnly 必要条件：只读、幂等、无持久副作用。
    public var meetsPlanningSafeReadOnlyGuarantees: Bool {
        !writeRisk && !escalationRisk && !networkRisk
    }
}

/// 原子工具目录（签名、固定 revision）。
public struct StacioToolCatalog: Equatable, Sendable {
    public let revision: Int
    public let tools: [StacioToolDescriptor]

    public init(revision: Int, tools: [StacioToolDescriptor]) {
        self.revision = revision
        self.tools = tools
    }

    public func descriptor(for toolID: String) -> StacioToolDescriptor? {
        tools.first { $0.toolID == toolID }
    }
}

/// Signed Runtime Catalog resource envelope. The resource schema and the
/// catalog revision are intentionally separate: the former controls decoding,
/// while the latter is frozen into each Attempt for authorization.
public struct StacioToolCatalogDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let tools: [StacioToolDescriptor]

    public init(schemaVersion: Int = 1, revision: Int, tools: [StacioToolDescriptor]) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.tools = tools
    }
}

public enum StacioToolCatalogError: Error, Equatable {
    case duplicateToolID(String)
    case planningSafeReadOnlyCannotBeUserChecked(String)
    case planningSafeReadOnlyWithoutGuarantees(String)
    case missingRequiredFields(String)
    case userEditableExecutable(String)
}
