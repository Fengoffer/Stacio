import Foundation

// MARK: - Tool Capability Snapshot（P4-11，冻结进 Attempt）

/// 工具启停与目录 revision 冻结进 Attempt 的不可变快照。
public struct ToolCapabilitySnapshot: Codable, Equatable, Hashable, Sendable {
    public let catalogRevision: Int
    public let enabledToolIDs: [String]
    public let targetBindingDigest: String

    public init(catalogRevision: Int, enabledToolIDs: [String], targetBindingDigest: String) {
        self.catalogRevision = catalogRevision
        self.enabledToolIDs = enabledToolIDs
        self.targetBindingDigest = targetBindingDigest
    }

    public func includes(_ toolID: String) -> Bool {
        enabledToolIDs.contains(toolID)
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let value = String(data: try encoder.encode(self), encoding: .utf8) else {
            throw ToolCapabilitySnapshotError.encodingFailed
        }
        return value
    }
}

public enum ToolCapabilitySnapshotError: Error, Equatable {
    case encodingFailed
}

public enum ToolEnablementPolicy {

    /// 「启用工具」只代表 Runtime 可以提出 proposal，不代表预批准。
    public static func enabledMeansProposalOnly() -> Bool { true }

    /// 写入/终端/提权/破坏性工具即使启用仍逐次经过 Policy/Decision。
    public static func stillRequiresDecisionPerUse(tool: StacioToolDescriptor) -> Bool {
        tool.writeRisk || tool.escalationRisk || tool.networkRisk
    }

    /// 新安装可启用已验证只读诊断工具（零写/提权/网络风险）。
    public static func newInstallCanEnableReadOnlyDiagnostic(tool: StacioToolDescriptor) -> Bool {
        !tool.writeRisk && !tool.escalationRisk && !tool.networkRisk
    }

    /// 启停与目录 revision 冻结进 Attempt（Attempt 期间不漂移）。
    public static func frozenIntoAttempt() -> Bool { true }
}
