import Foundation

// MARK: - 模型目录服务（P4-5，无预置模型）

/// 模型集合状态：新配置全部为空（无预置模型）。
public struct ProviderModelCatalogState: Equatable, Sendable {
    /// 上游真实模型 ID（discovered）。
    public var discoveredModelIDs: [String]
    /// 手动声明模型 ID（`provider.manageManualModelIDs`，来源 `userDeclared`）。
    public var manualModelIDs: [String]
    public var enabledModelIDs: [String]
    public var defaultModelID: String?

    public init(
        discoveredModelIDs: [String] = [],
        manualModelIDs: [String] = [],
        enabledModelIDs: [String] = [],
        defaultModelID: String? = nil
    ) {
        self.discoveredModelIDs = discoveredModelIDs
        self.manualModelIDs = manualModelIDs
        self.enabledModelIDs = enabledModelIDs
        self.defaultModelID = defaultModelID
    }

    /// 新配置：discoveredModels/manualModelIDs/enabledModelIDs/defaultModelID 全空。
    public var isFreshConfiguration: Bool {
        discoveredModelIDs.isEmpty && manualModelIDs.isEmpty
            && enabledModelIDs.isEmpty && defaultModelID == nil
    }
}

public enum ModelCatalogServiceError: Error, Equatable {
    case manualModelsNotAllowed
    case cannotEnableUntestedManualModel
    case defaultModelMustBeExplicit
    case testFailed
    case manualModelIDUnknown(String)
}

/// 模型列表 endpoint 策略：`/models`、`/v1/models` 与 descriptor 专用策略。
public enum ProviderModelEndpointPolicy: String, Codable, Equatable, Sendable {
    case modelsRoot
    case v1Models
    case descriptorSpecific

    public static func policy(forDescriptorStrategy strategy: String?) -> ProviderModelEndpointPolicy {
        switch strategy {
        case "v1/models":
            return .v1Models
        case "descriptorSpecific":
            return .descriptorSpecific
        default:
            return .modelsRoot
        }
    }
}

public enum ProviderModelCatalogService {

    /// 新配置全空（无预置模型、默认模型必须显式选择）。
    public static func freshState() -> ProviderModelCatalogState {
        ProviderModelCatalogState()
    }

    /// 模型选择只显示上游真实 ID：discovered + 已启用的 userDeclared manual。
    public static func visibleModelIDs(state: ProviderModelCatalogState) -> [String] {
        var visible = state.discoveredModelIDs
        for manual in state.manualModelIDs where state.enabledModelIDs.contains(manual) {
            if !visible.contains(manual) {
                visible.append(manual)
            }
        }
        return visible
    }

    /// `provider.manageManualModelIDs` 仅「无枚举契约」自定义源可用
    /// （有枚举契约的源必须从上游枚举获取，禁止手工注入）。
    public static func manualModelsAllowed(hasEnumerationContract: Bool) -> Bool {
        !hasEnumerationContract
    }

    /// 测试前不可启用：manual 模型必须经连接测试（真实上游确认）后才能启用。
    public static func canEnable(manualModelID: String, state: ProviderModelCatalogState, connectionTested: Bool) -> Bool {
        guard state.manualModelIDs.contains(manualModelID) else { return false }
        return connectionTested
    }

    /// 默认模型必须显式选择：只允许从可见模型中选择，且已启用。
    public static func canBecomeDefault(modelID: String, state: ProviderModelCatalogState) -> Bool {
        visibleModelIDs(state: state).contains(modelID) && state.enabledModelIDs.contains(modelID)
    }

    /// 测试通过 + 默认模型有效 → ReadyToActivate。
    public static func readyToActivate(connectionTested: Bool, defaultModelValid: Bool) -> Bool {
        connectionTested && defaultModelValid
    }

    /// 启用 manual 模型（校验：允许 + 已测试）。
    public static func enableManualModel(
        modelID: String, state: ProviderModelCatalogState,
        hasEnumerationContract: Bool, connectionTested: Bool
    ) -> Result<ProviderModelCatalogState, ModelCatalogServiceError> {
        guard manualModelsAllowed(hasEnumerationContract: hasEnumerationContract) else {
            return .failure(.manualModelsNotAllowed)
        }
        guard state.manualModelIDs.contains(modelID) else {
            return .failure(.manualModelIDUnknown(modelID))
        }
        guard connectionTested else {
            return .failure(.cannotEnableUntestedManualModel)
        }
        var newState = state
        if !newState.enabledModelIDs.contains(modelID) {
            newState.enabledModelIDs.append(modelID)
        }
        return .success(newState)
    }
}

// MARK: - ProviderConnectionVerifier（复用 OpenAICompatibleAIModelCatalog 语义）

public struct ProviderConnectionVerificationResult: Equatable, Sendable {
    public let succeeded: Bool
    public let discoveredModelIDs: [String]

    public init(succeeded: Bool, discoveredModelIDs: [String]) {
        self.succeeded = succeeded
        self.discoveredModelIDs = discoveredModelIDs
    }
}

/// 连接测试抽象（真实实现复用 OpenAICompatibleAIModelCatalog / AIAssistantConnectionTester）。
public protocol ProviderConnectionTesting {
    func verify(endpoint: URL, apiKey: String?) -> ProviderConnectionVerificationResult
}

public final class ProviderConnectionVerifier {
    private let tester: ProviderConnectionTesting

    public init(tester: ProviderConnectionTesting) {
        self.tester = tester
    }

    /// 测试连接并发现上游模型；失败不产生模型发现。
    public func verify(endpoint: URL, apiKey: String?) -> ProviderConnectionVerificationResult {
        tester.verify(endpoint: endpoint, apiKey: apiKey)
    }
}
