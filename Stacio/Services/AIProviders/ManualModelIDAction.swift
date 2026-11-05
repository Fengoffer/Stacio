import Foundation

// MARK: - 手动模型 ID（P4-9b）

public enum ManualModelIDError: Error, Equatable {
    case notAllowed
    case invalidLength
    case controlCharacters
    case duplicate
    case unknownModelID(String)
    case unavailable(String)
}

/// 删除影响预览：默认/已启用项先展示影响。
public struct ManualModelRemovalImpact: Equatable, Sendable {
    public let isDefault: Bool
    public let isEnabled: Bool
    public let referencingConfigurations: [String]

    public init(isDefault: Bool, isEnabled: Bool, referencingConfigurations: [String]) {
        self.isDefault = isDefault
        self.isEnabled = isEnabled
        self.referencingConfigurations = referencingConfigurations
    }

    public var hasImpact: Bool {
        isDefault || isEnabled || !referencingConfigurations.isEmpty
    }
}

public enum ManualModelIDAction {
    public static let maxLength = 200
    public static let source = "userDeclared"

    /// `provider.manageManualModelIDs` 只在自定义兼容源 descriptor 明确无枚举契约时出现；
    /// 预置 Provider/Coding Plan 不可用。
    public static func available(hasEnumerationContract: Bool?) -> Bool {
        hasEnumerationContract == false
    }

    /// 原子校验：长度/控制字符/重复。
    public static func validate(modelID: String, existing: Set<String>) -> Result<Void, ManualModelIDError> {
        guard !modelID.isEmpty, modelID.count <= maxLength else {
            return .failure(.invalidLength)
        }
        guard !modelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.controlCharacters)
        }
        guard !existing.contains(modelID) else {
            return .failure(.duplicate)
        }
        return .success(())
    }

    /// 逐项添加精确模型 ID 并标记 `userDeclared`（原子校验失败则不添加）。
    public static func add(
        modelID: String, to state: ProviderModelCatalogState,
        hasEnumerationContract: Bool?
    ) -> Result<ProviderModelCatalogState, ManualModelIDError> {
        guard available(hasEnumerationContract: hasEnumerationContract) else {
            return .failure(.notAllowed)
        }
        switch validate(modelID: modelID, existing: Set(state.manualModelIDs)) {
        case .failure(let error):
            return .failure(error)
        case .success:
            var newState = state
            newState.manualModelIDs.append(modelID)
            return .success(newState)
        }
    }

    /// 编辑：精确替换 ID（不允许重命名到已存在项）。
    public static func edit(
        oldID: String, newID: String, state: ProviderModelCatalogState,
        hasEnumerationContract: Bool?
    ) -> Result<ProviderModelCatalogState, ManualModelIDError> {
        guard available(hasEnumerationContract: hasEnumerationContract) else {
            return .failure(.notAllowed)
        }
        guard state.manualModelIDs.contains(oldID) else {
            return .failure(.unknownModelID(oldID))
        }
        switch validate(modelID: newID, existing: Set(state.manualModelIDs.filter { $0 != oldID })) {
        case .failure(let error):
            return .failure(error)
        case .success:
            var newState = state
            if let index = newState.manualModelIDs.firstIndex(of: oldID) {
                newState.manualModelIDs[index] = newID
            }
            if newState.defaultModelID == oldID {
                newState.defaultModelID = newID
            }
            if let index = newState.enabledModelIDs.firstIndex(of: oldID) {
                newState.enabledModelIDs[index] = newID
            }
            return .success(newState)
        }
    }

    /// 删除：先展示影响（默认/已启用/引用配置）。
    public static func removalImpact(modelID: String, state: ProviderModelCatalogState) -> ManualModelRemovalImpact {
        ManualModelRemovalImpact(
            isDefault: state.defaultModelID == modelID,
            isEnabled: state.enabledModelIDs.contains(modelID),
            referencingConfigurations: []
        )
    }

    public static func remove(
        modelID: String, state: ProviderModelCatalogState,
        hasEnumerationContract: Bool?
    ) -> Result<ProviderModelCatalogState, ManualModelIDError> {
        guard available(hasEnumerationContract: hasEnumerationContract) else {
            return .failure(.notAllowed)
        }
        guard state.manualModelIDs.contains(modelID) else {
            return .failure(.unknownModelID(modelID))
        }
        var newState = state
        newState.manualModelIDs.removeAll { $0 == modelID }
        newState.enabledModelIDs.removeAll { $0 == modelID }
        if newState.defaultModelID == modelID {
            newState.defaultModelID = nil
        }
        return .success(newState)
    }

    /// 切换到可枚举协议后失效：manual 集合不再可用（后续操作必须经枚举）。
    public static func invalidatedWhenEnumerationAppears(hasEnumerationContract: Bool?) -> Bool {
        hasEnumerationContract == true
    }

    /// 不回填 discoveredModels/价格/能力/支持等级：manual 项永远只是 userDeclared 标识。
    public static func neverBackfills() -> Bool { true }
}
