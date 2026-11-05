import Foundation

// MARK: - Tool Availability Resolver（P4-11）

/// Runtime 提出工具时的判定结果。
public enum ToolAvailabilityOutcome: Equatable, Sendable {
    case available(StacioToolDescriptor)
    /// Runtime 提出未声明或 revision 不匹配工具 → 协议错误拒绝。
    case undeclaredTool(String)
    case revisionMismatch(toolID: String, declared: Int, catalog: Int)
    /// 无法映射到已声明 Stacio tool ID → 显示「不支持的工具」，不直接执行、不转 shell 猜测。
    case unsupportedTool(String)
    /// managed 未登记的外部工具 endpoint → containment 阻断。
    case endpointBlocked(String)
}

public enum ToolAvailabilityResolver {

    /// 解析 Runtime 声明：必须命中目录且 schema revision 匹配。
    public static func resolve(
        runtimeToolID: String, declaredRevision: Int?,
        catalog: StacioToolCatalog
    ) -> ToolAvailabilityOutcome {
        guard let descriptor = catalog.descriptor(for: runtimeToolID) else {
            return .undeclaredTool(runtimeToolID)
        }
        if let declared = declaredRevision, declared != descriptor.schemaRevision {
            return .revisionMismatch(toolID: runtimeToolID, declared: declared, catalog: descriptor.schemaRevision)
        }
        return .available(descriptor)
    }

    /// 无法映射的操作显示「不支持的工具」，不直接执行、不转 shell 猜测。
    public static func unmappableToolDisplay() -> String { "不支持的工具" }
    public static func neverTranslateUnmappableToShell() -> Bool { true }

    /// managed 未登记的外部工具 endpoint 被 containment 阻断。
    public static func blocksUndeclaredEndpoint(endpointID: String, registeredEndpoints: Set<String>) -> Bool {
        !registeredEndpoints.contains(endpointID)
    }
}

/// Full proposal admission result used immediately before a Runtime proposal
/// becomes durable. Every value comes from the frozen Attempt snapshot or the
/// hash-verified catalog, never from mutable Settings UI state.
public enum ToolProposalAdmissionOutcome: Equatable, Sendable {
    case available(StacioToolDescriptor)
    case catalogRevisionMismatch(snapshot: Int, catalog: Int)
    case undeclaredTool(String)
    case schemaRevisionMissing(String)
    case schemaRevisionMismatch(toolID: String, declared: Int, catalog: Int)
    case toolDisabled(String)
    case targetBindingMismatch
    case targetBindingUnsupported(toolID: String, kind: String)
    case inputTooLarge(toolID: String, maximum: Int, actual: Int)
}

public enum ToolProposalAdmissionGate {
    public static func evaluate(
        toolID: String,
        schemaRevision: Int?,
        inputByteCount: Int,
        targetBindingKind: String,
        targetBindingDigest: String,
        snapshot: ToolCapabilitySnapshot,
        catalog: StacioToolCatalog
    ) -> ToolProposalAdmissionOutcome {
        guard snapshot.catalogRevision == catalog.revision else {
            return .catalogRevisionMismatch(snapshot: snapshot.catalogRevision, catalog: catalog.revision)
        }
        guard snapshot.targetBindingDigest == targetBindingDigest else {
            return .targetBindingMismatch
        }
        guard let descriptor = catalog.descriptor(for: toolID) else {
            return .undeclaredTool(toolID)
        }
        guard let schemaRevision else {
            return .schemaRevisionMissing(toolID)
        }
        guard schemaRevision == descriptor.schemaRevision else {
            return .schemaRevisionMismatch(
                toolID: toolID,
                declared: schemaRevision,
                catalog: descriptor.schemaRevision
            )
        }
        guard snapshot.includes(toolID) else {
            return .toolDisabled(toolID)
        }
        guard descriptor.applicableTargetBindingKinds.contains(targetBindingKind) else {
            return .targetBindingUnsupported(toolID: toolID, kind: targetBindingKind)
        }
        guard inputByteCount <= descriptor.maxInputBytes else {
            return .inputTooLarge(
                toolID: toolID,
                maximum: descriptor.maxInputBytes,
                actual: inputByteCount
            )
        }
        return .available(descriptor)
    }
}
