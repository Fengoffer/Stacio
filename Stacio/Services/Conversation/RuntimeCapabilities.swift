import Foundation

// MARK: - Runtime 能力解析与校验（规格 §8.4/§10.4）

/// 用户试图手动提升的能力请求（UI 不得直接写入能力字段）。
public struct RuntimeUserElevationRequest: Equatable, Sendable {
    public var managedExecution: Bool = false
    public var launchCapabilityBinding: Bool = false
    public var workModeEnforcement: Bool = false
    public var answerOnlyRuntimeLaunch: Bool = false

    public init(
        managedExecution: Bool = false,
        launchCapabilityBinding: Bool = false,
        workModeEnforcement: Bool = false,
        answerOnlyRuntimeLaunch: Bool = false
    ) {
        self.managedExecution = managedExecution
        self.launchCapabilityBinding = launchCapabilityBinding
        self.workModeEnforcement = workModeEnforcement
        self.answerOnlyRuntimeLaunch = answerOnlyRuntimeLaunch
    }
}

public enum RuntimeCapabilityResolver {
    /// 能力只来自协议握手/工具目录/配置；`displayName` 不贡献任何能力（供应商显示名不得猜测能力）。
    public static func resolve(capabilities: RuntimeCapabilities, displayName: String) -> RuntimeCapabilities {
        _ = displayName
        return capabilities
    }

    /// 冻结到 Attempt snapshot 的确定性 digest（同一 Attempt 内能力不可变）。
    public static func snapshotDigest(for capabilities: RuntimeCapabilities) -> String {
        [
            "streaming=\(capabilities.streaming)",
            "toolCalling=\(capabilities.toolCalling)",
            "tools=\(capabilities.availableToolIDs.sorted().joined(separator: ","))",
            "catalog=\(capabilities.toolCatalogRevision ?? "")",
            "structuredApproval=\(capabilities.structuredApproval)",
            "requestUserInput=\(capabilities.requestUserInput)",
            "sensitiveInput=\(capabilities.sensitiveInput)",
            "steering=\(capabilities.steering)",
            "checkpointPause=\(capabilities.checkpointPause)",
            "sessionResume=\(capabilities.sessionResume)",
            "imageInput=\(capabilities.imageInput)",
            "reasoningEffort=\(capabilities.reasoningEffort)",
            "subagents=\(capabilities.subagents)",
            "terminalTakeover=\(capabilities.terminalTakeover)",
            "structuredEvents=\(capabilities.structuredEvents)",
            "managedExecution=\(capabilities.managedExecution)",
            "launchCapabilityBinding=\(capabilities.launchCapabilityBinding)",
            "answerRegeneration=\(capabilities.answerRegeneration)",
            "answerOnlyRuntimeLaunch=\(capabilities.answerOnlyRuntimeLaunch)",
            "workModeEnforcement=\(capabilities.workModeEnforcement)",
            "allowedWorkModes=\(capabilities.allowedWorkModes.map(\.rawValue).joined(separator: ","))"
        ].joined(separator: "|")
    }

    /// 未声明工具拒绝。
    public static func declaresTool(_ toolID: String, in capabilities: RuntimeCapabilities) -> Bool {
        capabilities.availableToolIDs.contains(toolID)
    }

    /// 用户手动提升检查：请求了 capabilities 未声明的能力 → blocked。
    public static func userElevationBlocked(
        capabilities: RuntimeCapabilities,
        requested: RuntimeUserElevationRequest
    ) -> Bool {
        (requested.managedExecution && !capabilities.managedExecution)
            || (requested.launchCapabilityBinding && !capabilities.launchCapabilityBinding)
            || (requested.workModeEnforcement && !capabilities.workModeEnforcement)
            || (requested.answerOnlyRuntimeLaunch && !capabilities.answerOnlyRuntimeLaunch)
    }

    /// 纯 PTY 能力集：永远无 workModeEnforcement / answerOnlyRuntimeLaunch / managedExecution。
    public static func ptyCapabilities() -> RuntimeCapabilities {
        RuntimeCapabilities(
            streaming: true,
            toolCalling: false,
            availableToolIDs: [],
            structuredApproval: false,
            requestUserInput: false,
            sensitiveInput: false,
            steering: false,
            checkpointPause: false,
            sessionResume: false,
            imageInput: false,
            reasoningEffort: false,
            subagents: false,
            terminalTakeover: false,
            structuredEvents: false,
            managedExecution: false,
            launchCapabilityBinding: false,
            answerRegeneration: false,
            answerOnlyRuntimeLaunch: false,
            workModeEnforcement: false,
            allowedWorkModes: [],
            contextUsageReporting: false,
            usageReporting: false
        )
    }
}
