import Foundation

// MARK: - Stacio Tool Catalog Loader（P4-11）

/// 加载 + 校验：固定 tool ID 唯一、schema revision、planningSafeReadOnly 仅签名目录声明
/// 且必须满足只读/幂等/无持久副作用；executable/argv 不可由设置页编辑。
public enum StacioToolCatalogLoader {

    public static func load(
        revision: Int, tools: [StacioToolDescriptor], userCheckedPlanningSafeReadOnlyIDs: Set<String>
    ) throws -> StacioToolCatalog {
        var byID: Set<String> = []
        for tool in tools {
            guard !tool.toolID.isEmpty, tool.schemaRevision >= 1,
                  !tool.applicableTargetBindingKinds.isEmpty,
                  tool.maxInputBytes > 0, tool.maxOutputBytes > 0,
                  !tool.auditPolicy.isEmpty
            else {
                throw StacioToolCatalogError.missingRequiredFields(tool.toolID)
            }
            guard !byID.contains(tool.toolID) else {
                throw StacioToolCatalogError.duplicateToolID(tool.toolID)
            }
            byID.insert(tool.toolID)
            // planningSafeReadOnly 只能由签名 Catalog 声明（用户不能自行勾选）
            if userCheckedPlanningSafeReadOnlyIDs.contains(tool.toolID) {
                throw StacioToolCatalogError.planningSafeReadOnlyCannotBeUserChecked(tool.toolID)
            }
            if tool.planningSafeReadOnly && !tool.meetsPlanningSafeReadOnlyGuarantees {
                throw StacioToolCatalogError.planningSafeReadOnlyWithoutGuarantees(tool.toolID)
            }
            // executable/argv 由签名目录锁定；设置页不得提供可编辑入口
            if tool.executable == nil, tool.argv != nil {
                throw StacioToolCatalogError.userEditableExecutable(tool.toolID)
            }
        }
        return StacioToolCatalog(revision: revision, tools: tools)
    }

    /// 设置页不能编辑 executable/argv/schema 冒充内置工具。
    public static func settingsCanEditExecutable(tool: StacioToolDescriptor) -> Bool {
        false
    }

    /// 导入配置不携带隐藏工具授权。
    public static func importCarriesHiddenToolAuthorization() -> Bool { false }

    /// 本期没有「添加 MCP Server」按钮。
    public static func hasAddMCPServerButton() -> Bool { false }
}
