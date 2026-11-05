import Foundation

// MARK: - 关闭分类表（P4-1，规格 §9 信息架构）

/// Setting 值类型。
public enum SettingValueType: String, Codable, CaseIterable, Equatable, Sendable {
    case string
    case int
    case bool
    case double
    case stringArray
    case structured
}

/// 敏感度（关闭五值）：新增无法分类的 descriptor → Registry 构建失败。
public enum SettingSensitivity: String, Codable, CaseIterable, Equatable, Sendable {
    case publicValue
    case privateValue
    case sensitive
    case secret
    case credential
}

/// 导出策略（关闭三值）。
public enum SettingExportPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case alwaysExclude
    case includeValue
    case includeRedacted
}

/// writeControlPolicy（关闭三值）：`actionOnly` 路径不能被父对象批量 setter 绕过。
public enum SettingWriteControlPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    case userWritable
    case actionOnly
    case readOnlyProjection
}

/// 14 个 operation kind 中可承载 setting 写入的子集（§8.1 首版 contract）。
public enum SettingWriteOperationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case configurationMutation
    case configurationDelete
    case localAgentMaintenanceLaunch
    case runtimeLaunch
}

// MARK: - 作用域与生效边界

public enum SettingScope: String, Codable, CaseIterable, Equatable, Sendable {
    case global
    case provider
    case localAgent
    case sessionDefault
}

/// 生效边界：设置变化只影响后续 Turn/Attempt/Invocation，不修改已冻结快照。
public enum SettingApplyBoundary: String, Codable, CaseIterable, Equatable, Sendable {
    case nextTurn
    case nextAttempt
    case nextInvocation
    case nextSession
}

public enum SettingResetBehavior: String, Codable, CaseIterable, Equatable, Sendable {
    case restoreDefault
    case keepUserValue
    case keepUntilSessionEnd
}

public enum SettingDefaultSource: String, Codable, CaseIterable, Equatable, Sendable {
    case registry
    case provider
    case localAgent
}

/// 关闭分类（§9.1 页面）。
public enum SettingCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case general
    case session
    case execution
    case provider
    case codingPlan
    case localAgent
    case content
    case privacy
    case storage
    case appearance
}

/// Settings 信息架构的 19 个稳定页面。`SettingCategory` 用于存储分区，
/// `SettingPage` 用于界面归属；二者不能由 ViewController 自行猜测。
public enum AssistantSettingsPage: String, Codable, CaseIterable, Equatable, Sendable {
    case general
    case providers
    case providerDetails
    case providerAdvanced
    case models
    case codingPlan
    case localAgent
    case execution
    case usageAndCost
    case toolsAndCapabilities
    case permissionsAndSecurity
    case instructionsAndProjectRules
    case context
    case memoryAndHistory
    case storageAndQuota
    case notifications
    case privacy
    case appearanceAndAccessibility
    case advancedDiagnostics
}

// MARK: - sizeLimit（计划 P4-1 Step 1 字面表）

public struct SettingSizeLimit: Equatable, Sendable {
    public var maxCount: Int?
    public var maxItemBytes: Int?
    public var maxTotalBytes: Int?
    public var maxLengthChars: Int?

    public init(maxCount: Int? = nil, maxItemBytes: Int? = nil, maxTotalBytes: Int? = nil, maxLengthChars: Int? = nil) {
        self.maxCount = maxCount
        self.maxItemBytes = maxItemBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxLengthChars = maxLengthChars
    }
}

// MARK: - 值

public enum SettingValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case double(Double)
    case stringArray([String])
    case structured(Data)
}

// MARK: - SettingDescriptor（14 个必含字段）

public struct SettingDescriptor: Equatable, Sendable {
    public let id: String
    public let valueType: SettingValueType
    public let category: SettingCategory
    public let page: AssistantSettingsPage
    public let allowedValues: [String]?
    public let range: ClosedRange<Int>?
    public let sizeLimit: SettingSizeLimit?
    public let defaultValue: SettingValue
    public let defaultSource: SettingDefaultSource
    public let scope: SettingScope
    public let applyBoundary: SettingApplyBoundary
    public let sensitivity: SettingSensitivity
    public let exportPolicy: SettingExportPolicy
    public let defaultExportSelection: Bool
    public let resetBehavior: SettingResetBehavior
    public let migrationKey: String
    public let writeControlPolicy: SettingWriteControlPolicy
    public let writeOperationKind: SettingWriteOperationKind?

    public init(
        id: String,
        valueType: SettingValueType,
        category: SettingCategory,
        page: AssistantSettingsPage = .general,
        allowedValues: [String]? = nil,
        range: ClosedRange<Int>? = nil,
        sizeLimit: SettingSizeLimit? = nil,
        defaultValue: SettingValue,
        defaultSource: SettingDefaultSource = .registry,
        scope: SettingScope,
        applyBoundary: SettingApplyBoundary,
        sensitivity: SettingSensitivity,
        exportPolicy: SettingExportPolicy,
        defaultExportSelection: Bool,
        resetBehavior: SettingResetBehavior,
        migrationKey: String,
        writeControlPolicy: SettingWriteControlPolicy,
        writeOperationKind: SettingWriteOperationKind? = nil
    ) {
        self.id = id
        self.valueType = valueType
        self.category = category
        self.page = page
        self.allowedValues = allowedValues
        self.range = range
        self.sizeLimit = sizeLimit
        self.defaultValue = defaultValue
        self.defaultSource = defaultSource
        self.scope = scope
        self.applyBoundary = applyBoundary
        self.sensitivity = sensitivity
        self.exportPolicy = exportPolicy
        self.defaultExportSelection = defaultExportSelection
        self.resetBehavior = resetBehavior
        self.migrationKey = migrationKey
        self.writeControlPolicy = writeControlPolicy
        self.writeOperationKind = writeOperationKind
    }
}

// MARK: - 构建错误与解析结果

public enum SettingRegistryError: Error, Equatable {
    /// 缺少必含字段的 descriptor id 列表。
    case missingRequiredFields([String])
    /// 重复 ID。
    case duplicateID(String)
    /// 未知迁移键（migrationKey 必须可追溯到已知迁移）。
    case unknownMigrationKey(String)
}

/// NeedsReview 语义：未知 ID/错误类型/越界值/新版本已删除枚举 → 需要人工审查，
/// 不回退第一个选项（不自动替换）。
public enum ResolvedSettingValue: Equatable {
    case valid(SettingValue)
    case wrongType(SettingValue)
    case outOfRange(SettingValue)
    case needsReview
}

// MARK: - 快照（页面唯一 truth；页面不能另造第二套默认值）

public struct AssistantSettingRegistrySnapshot: Equatable, Sendable {
    public let defaultsByID: [String: SettingValue]
    public let sizeLimitsByID: [String: SettingSizeLimit?]
    public let writePoliciesByID: [String: SettingWriteControlPolicy]
    public let revision: Int

    public init(
        defaultsByID: [String: SettingValue],
        sizeLimitsByID: [String: SettingSizeLimit?],
        writePoliciesByID: [String: SettingWriteControlPolicy],
        revision: Int
    ) {
        self.defaultsByID = defaultsByID
        self.sizeLimitsByID = sizeLimitsByID
        self.writePoliciesByID = writePoliciesByID
        self.revision = revision
    }
}

// MARK: - AssistantSettingRegistry

/// 唯一 Setting schema：构建期校验每个 descriptor 必含全部字段；
/// `snapshot()` 是页面默认值/上限/writeControlPolicy 的唯一 truth。
public struct AssistantSettingRegistry {
    public let descriptorsByID: [String: SettingDescriptor]
    public let revision: Int

    /// 构建期校验：任一 descriptor 缺必含字段 → 构建失败。
    public static func build(descriptors: [SettingDescriptor], revision: Int = 1) throws -> AssistantSettingRegistry {
        var byID: [String: SettingDescriptor] = [:]
        var missing: [String] = []
        for descriptor in descriptors {
            if byID[descriptor.id] != nil {
                throw SettingRegistryError.duplicateID(descriptor.id)
            }
            if requiredFieldsMissing(descriptor) {
                missing.append(descriptor.id)
            }
            byID[descriptor.id] = descriptor
        }
        if !missing.isEmpty {
            throw SettingRegistryError.missingRequiredFields(missing)
        }
        return AssistantSettingRegistry(descriptorsByID: byID, revision: revision)
    }

    /// 14 个必含字段：id/valueType/allowedValues-range-sizeLimit/defaultValue-defaultSource/
    /// scope/applyBoundary/sensitivity/exportPolicy-defaultExportSelection/resetBehavior/
    /// migrationKey/writeControlPolicy/writeOperationKind。
    private static func requiredFieldsMissing(_ descriptor: SettingDescriptor) -> Bool {
        if descriptor.id.isEmpty { return true }
        if descriptor.defaultValue == .string("") && descriptor.valueType != .string { return true }
        // sensitivity/exportPolicy/writeControlPolicy 必须是关闭集合成员（枚举本身保证）；
        // migrationKey 必须非空（可追溯）。
        if descriptor.migrationKey.isEmpty { return true }
        // actionOnly 必须声明承载它的 operation kind（否则无法经 action 写入）。
        if descriptor.writeControlPolicy == .actionOnly && descriptor.writeOperationKind == nil {
            return true
        }
        return false
    }

    public func descriptor(for id: String) -> SettingDescriptor? {
        if let exact = descriptorsByID[id] {
            return exact
        }
        for descriptor in descriptorsByID.values where descriptor.id.contains("{id}") {
            let parts = descriptor.id.components(separatedBy: "{id}")
            guard parts.count == 2,
                  id.hasPrefix(parts[0]),
                  id.hasSuffix(parts[1]),
                  id.count > parts[0].count + parts[1].count
            else { continue }
            return descriptor.instantiated(as: id)
        }
        return nil
    }

    /// NeedsReview 判定：未知 ID → needsReview；错误类型 → wrongType；
    /// 越界值/新版本已删除枚举 → outOfRange/needsReview（不回退第一个选项）。
    public func resolve(value: SettingValue, for id: String) -> ResolvedSettingValue {
        guard let descriptor = descriptor(for: id) else {
            return .needsReview
        }
        if !typeMatches(value, descriptor.valueType) {
            return .wrongType(value)
        }
        switch value {
        case .int(let intValue):
            if let range = descriptor.range, !range.contains(intValue) {
                return .outOfRange(value)
            }
        case .string(let stringValue):
            if let allowed = descriptor.allowedValues, !allowed.contains(stringValue) {
                // 新版本已删除枚举：不回退第一个选项
                return .needsReview
            }
            // 长度上限按 UTF-8 字节计（避免中文字符数偏差超字节预算）
            if let limit = descriptor.sizeLimit?.maxLengthChars, stringValue.utf8.count > limit {
                return .outOfRange(value)
            }
        case .stringArray(let items):
            if let limit = descriptor.sizeLimit?.maxCount, items.count > limit {
                return .outOfRange(value)
            }
            if let limit = descriptor.sizeLimit?.maxItemBytes,
               items.contains(where: { $0.utf8.count > limit }) {
                return .outOfRange(value)
            }
            if let limit = descriptor.sizeLimit?.maxTotalBytes {
                let total = items.reduce(0) { $0 + $1.utf8.count }
                if total > limit { return .outOfRange(value) }
            }
        case .structured(let data):
            if let limit = descriptor.sizeLimit?.maxTotalBytes, data.count > limit {
                return .outOfRange(value)
            }
            if let limit = descriptor.sizeLimit?.maxLengthChars, data.count > limit {
                return .outOfRange(value)
            }
        default:
            break
        }
        return .valid(value)
    }

    /// actionOnly/readOnlyProjection 路径不能被父对象批量 setter 绕过（只有 userWritable 可批量写）。
    public func bulkSetterCanWrite(id: String) -> Bool {
        guard let descriptor = descriptor(for: id) else { return false }
        return descriptor.writeControlPolicy == .userWritable
    }

    public func snapshot() -> AssistantSettingRegistrySnapshot {
        AssistantSettingRegistrySnapshot(
            defaultsByID: descriptorsByID.mapValues(\.defaultValue),
            sizeLimitsByID: descriptorsByID.mapValues(\.sizeLimit),
            writePoliciesByID: descriptorsByID.mapValues(\.writeControlPolicy),
            revision: revision
        )
    }

    private func typeMatches(_ value: SettingValue, _ type: SettingValueType) -> Bool {
        switch (value, type) {
        case (.string, .string), (.int, .int), (.bool, .bool), (.double, .double),
             (.stringArray, .stringArray), (.structured, .structured):
            return true
        default:
            return false
        }
    }
}

private extension SettingDescriptor {
    func instantiated(as concreteID: String) -> SettingDescriptor {
        SettingDescriptor(
            id: concreteID,
            valueType: valueType,
            category: category,
            page: page,
            allowedValues: allowedValues,
            range: range,
            sizeLimit: sizeLimit,
            defaultValue: defaultValue,
            defaultSource: defaultSource,
            scope: scope,
            applyBoundary: applyBoundary,
            sensitivity: sensitivity,
            exportPolicy: exportPolicy,
            defaultExportSelection: defaultExportSelection,
            resetBehavior: resetBehavior,
            migrationKey: "\(concreteID).v1",
            writeControlPolicy: writeControlPolicy,
            writeOperationKind: writeOperationKind
        )
    }
}

// MARK: - 关闭分类唯一性（新增无法分类 → 构建失败）

public enum SettingCategoryResolver {
    /// 每个 descriptor 必须能归类到关闭分类之一（枚举类型本身保证）；
    /// 提供显式分类检查以便新增时构建失败而非静默归类。
    public static func classify(_ descriptor: SettingDescriptor) -> SettingCategory? {
        switch descriptor.category {
        case .general, .session, .execution, .provider, .codingPlan,
             .localAgent, .content, .privacy, .storage, .appearance:
            return descriptor.category
        }
    }
}

// MARK: - 标准 Registry（附录 D：92 个稳定 Setting ID）

public extension AssistantSettingRegistry {
    private static let cachedStandard: Result<AssistantSettingRegistry, SettingRegistryError> = {
        do {
            return .success(try buildStandard())
        } catch let error as SettingRegistryError {
            return .failure(error)
        } catch {
            return .failure(.missingRequiredFields([]))
        }
    }()

    static func standard() throws -> AssistantSettingRegistry {
        try cachedStandard.get()
    }

    private static func setting(
        _ id: String,
        _ valueType: SettingValueType,
        category: SettingCategory,
        page: AssistantSettingsPage,
        allowedValues: [String]? = nil,
        range: ClosedRange<Int>? = nil,
        sizeLimit: SettingSizeLimit? = nil,
        defaultValue: SettingValue,
        defaultSource: SettingDefaultSource = .registry,
        scope: SettingScope = .global,
        applyBoundary: SettingApplyBoundary = .nextAttempt,
        sensitivity: SettingSensitivity = .publicValue,
        exportPolicy: SettingExportPolicy = .includeValue,
        defaultExportSelection: Bool = true,
        resetBehavior: SettingResetBehavior = .restoreDefault,
        writeControlPolicy: SettingWriteControlPolicy = .userWritable,
        writeOperationKind: SettingWriteOperationKind? = nil
    ) -> SettingDescriptor {
        SettingDescriptor(
            id: id,
            valueType: valueType,
            category: category,
            page: page,
            allowedValues: allowedValues,
            range: range,
            sizeLimit: sizeLimit,
            defaultValue: defaultValue,
            defaultSource: defaultSource,
            scope: scope,
            applyBoundary: applyBoundary,
            sensitivity: sensitivity,
            exportPolicy: exportPolicy,
            defaultExportSelection: defaultExportSelection,
            resetBehavior: resetBehavior,
            migrationKey: "\(id).v1",
            writeControlPolicy: writeControlPolicy,
            writeOperationKind: writeOperationKind
        )
    }

    private static func configurationSetting(
        _ id: String,
        _ valueType: SettingValueType,
        category: SettingCategory,
        page: AssistantSettingsPage,
        allowedValues: [String]? = nil,
        range: ClosedRange<Int>? = nil,
        sizeLimit: SettingSizeLimit? = nil,
        defaultValue: SettingValue,
        defaultSource: SettingDefaultSource,
        scope: SettingScope,
        applyBoundary: SettingApplyBoundary = .nextAttempt,
        sensitivity: SettingSensitivity = .privateValue,
        exportPolicy: SettingExportPolicy = .includeRedacted,
        writeOperationKind: SettingWriteOperationKind = .configurationMutation
    ) -> SettingDescriptor {
        setting(
            id,
            valueType,
            category: category,
            page: page,
            allowedValues: allowedValues,
            range: range,
            sizeLimit: sizeLimit,
            defaultValue: defaultValue,
            defaultSource: defaultSource,
            scope: scope,
            applyBoundary: applyBoundary,
            sensitivity: sensitivity,
            exportPolicy: exportPolicy,
            defaultExportSelection: false,
            resetBehavior: .keepUserValue,
            writeControlPolicy: .actionOnly,
            writeOperationKind: writeOperationKind
        )
    }

    private static func buildStandard() throws -> AssistantSettingRegistry {
        let modelCollectionLimit = SettingSizeLimit(
            maxCount: 4_096,
            maxItemBytes: 512,
            maxTotalBytes: 4 * 1_024 * 1_024
        )
        let customHeadersLimit = SettingSizeLimit(
            maxCount: 64,
            maxItemBytes: 4 * 1_024,
            maxTotalBytes: 64 * 1_024
        )
        let websiteActionsLimit = SettingSizeLimit(
            maxCount: 64,
            maxItemBytes: 16,
            maxTotalBytes: 64 * 1_024
        )

        let descriptors: [SettingDescriptor] = [
            // assistant.general.* (9)
            setting("assistant.general.defaultRuntime", .string, category: .general, page: .general,
                    defaultValue: .string(""), scope: .sessionDefault, applyBoundary: .nextSession,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.general.defaultWorkMode", .string, category: .session, page: .general,
                    allowedValues: ["agent", "plan", "answer"], defaultValue: .string("agent"),
                    scope: .sessionDefault, applyBoundary: .nextTurn),
            setting("assistant.general.defaultReasoningEffort", .string, category: .session, page: .general,
                    allowedValues: ["low", "medium", "high"], defaultValue: .string("medium"),
                    scope: .sessionDefault, applyBoundary: .nextTurn),
            setting("assistant.general.queueAutoAdvance", .bool, category: .session, page: .general,
                    defaultValue: .bool(true), scope: .sessionDefault, applyBoundary: .nextTurn),
            setting("assistant.general.restoreLastConversation", .bool, category: .general, page: .general,
                    defaultValue: .bool(true), applyBoundary: .nextSession),
            setting("assistant.general.sendKeyMode", .string, category: .general, page: .general,
                    allowedValues: ["return", "commandReturn"], defaultValue: .string("return"),
                    applyBoundary: .nextSession),
            setting("assistant.general.localAutoTitle", .bool, category: .general, page: .general,
                    defaultValue: .bool(true), applyBoundary: .nextTurn,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.general.language", .string, category: .general, page: .general,
                    allowedValues: ["system", "zh-Hans", "en"], defaultValue: .string("system"),
                    applyBoundary: .nextSession),
            configurationSetting(
                "assistant.general.configurationOrder", .structured, category: .general, page: .providers,
                sizeLimit: SettingSizeLimit(maxLengthChars: 4_096), defaultValue: .structured(Data()),
                defaultSource: .registry, scope: .global
            ),

            // assistant.execution.* (9)
            setting("assistant.execution.defaultTerminalMode", .string, category: .execution, page: .execution,
                    allowedValues: ["realTerminal", "backgroundVirtualTerminal", "ask"],
                    defaultValue: .string("realTerminal"), scope: .sessionDefault, applyBoundary: .nextTurn),
            setting("assistant.execution.maxParallelAttempts", .int, category: .execution, page: .execution,
                    range: 1...4, defaultValue: .int(2), applyBoundary: .nextSession),
            setting("assistant.execution.capacityWaitMinutes", .int, category: .execution, page: .execution,
                    range: 1...120, defaultValue: .int(30), applyBoundary: .nextTurn),
            setting("assistant.execution.approvalDeadlineMinutes", .int, category: .execution, page: .execution,
                    range: 1...120, defaultValue: .int(10), applyBoundary: .nextTurn),
            setting("assistant.execution.userInputDeadline", .int, category: .execution, page: .execution,
                    range: 1...120, defaultValue: .int(30), applyBoundary: .nextTurn),
            setting("assistant.execution.maxEffectiveMinutes", .int, category: .execution, page: .execution,
                    range: 5...120, defaultValue: .int(30), applyBoundary: .nextTurn),
            setting("assistant.execution.maxToolSteps", .int, category: .execution, page: .execution,
                    range: 5...200, defaultValue: .int(40), applyBoundary: .nextAttempt),
            setting("assistant.execution.maxControlledChildTasks", .int, category: .execution, page: .execution,
                    range: 0...16, defaultValue: .int(4), applyBoundary: .nextAttempt),
            setting("assistant.execution.managedStopGraceSeconds", .int, category: .execution, page: .execution,
                    range: 1...60, defaultValue: .int(10), applyBoundary: .nextAttempt),

            // assistant.usage.* (5) + assistant.security.* (1)
            setting("assistant.usage.maxModelInvocations", .int, category: .execution, page: .usageAndCost,
                    range: 5...200, defaultValue: .int(40), applyBoundary: .nextAttempt),
            setting("assistant.usage.tokenWarningThreshold", .int, category: .execution, page: .usageAndCost,
                    range: 0...100_000_000, defaultValue: .int(0), applyBoundary: .nextAttempt),
            setting("assistant.usage.hardTokenLimit", .int, category: .execution, page: .usageAndCost,
                    range: 0...100_000_000, defaultValue: .int(0), applyBoundary: .nextAttempt),
            setting("assistant.usage.costWarning", .int, category: .execution, page: .usageAndCost,
                    range: 0...100_000_000, defaultValue: .int(0), applyBoundary: .nextAttempt),
            setting("assistant.usage.hardCostLimit", .int, category: .execution, page: .usageAndCost,
                    range: 0...100_000_000, defaultValue: .int(0), applyBoundary: .nextAttempt),
            setting("assistant.security.approvalLevel", .string, category: .execution, page: .permissionsAndSecurity,
                    allowedValues: ["strict", "balanced"], defaultValue: .string("balanced"),
                    scope: .sessionDefault, applyBoundary: .nextTurn),

            // provider.{id}.* (20)
            configurationSetting("provider.{id}.displayName", .string, category: .provider, page: .providerDetails,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("provider.{id}.enabled", .bool, category: .provider, page: .providers,
                                 defaultValue: .bool(false), defaultSource: .provider, scope: .provider),
            configurationSetting("provider.{id}.baseURL", .string, category: .provider, page: .providerDetails,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider,
                                 sensitivity: .sensitive, exportPolicy: .includeRedacted),
            configurationSetting("provider.{id}.protocol", .string, category: .provider, page: .providerDetails,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("provider.{id}.modelDiscoveryStrategy", .string, category: .provider, page: .models,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("provider.{id}.enabledModelIDs", .stringArray, category: .provider, page: .models,
                                 sizeLimit: modelCollectionLimit, defaultValue: .stringArray([]),
                                 defaultSource: .provider, scope: .provider),
            configurationSetting("provider.{id}.defaultModelID", .string, category: .provider, page: .models,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("provider.{id}.modelCapabilityOverrides", .structured, category: .provider, page: .models,
                                 sizeLimit: modelCollectionLimit, defaultValue: .structured(Data()),
                                 defaultSource: .provider, scope: .provider),
            configurationSetting("provider.{id}.connectionTimeoutSeconds", .int, category: .provider, page: .providerAdvanced,
                                 range: 1...300, defaultValue: .int(30), defaultSource: .provider,
                                 scope: .provider, applyBoundary: .nextInvocation, sensitivity: .publicValue,
                                 exportPolicy: .includeValue),
            configurationSetting("provider.{id}.firstByteTimeoutSeconds", .int, category: .provider, page: .providerAdvanced,
                                 range: 1...300, defaultValue: .int(60), defaultSource: .provider,
                                 scope: .provider, applyBoundary: .nextInvocation, sensitivity: .publicValue,
                                 exportPolicy: .includeValue),
            configurationSetting("provider.{id}.streamIdleTimeoutSeconds", .int, category: .provider, page: .providerAdvanced,
                                 range: 1...600, defaultValue: .int(120), defaultSource: .provider,
                                 scope: .provider, applyBoundary: .nextInvocation, sensitivity: .publicValue,
                                 exportPolicy: .includeValue),
            configurationSetting("provider.{id}.setupTimeoutSeconds", .int, category: .provider, page: .providerAdvanced,
                                 range: 10...1_800, defaultValue: .int(300), defaultSource: .provider,
                                 scope: .provider, sensitivity: .publicValue, exportPolicy: .includeValue),
            configurationSetting("provider.{id}.safeRetryCount", .int, category: .provider, page: .providerAdvanced,
                                 range: 0...3, defaultValue: .int(1), defaultSource: .provider,
                                 scope: .provider, applyBoundary: .nextInvocation, sensitivity: .publicValue,
                                 exportPolicy: .includeValue),
            configurationSetting("provider.{id}.userAgent", .string, category: .provider, page: .providerAdvanced,
                                 sizeLimit: SettingSizeLimit(maxLengthChars: 512), defaultValue: .string("Stacio"),
                                 defaultSource: .provider, scope: .provider, applyBoundary: .nextInvocation),
            configurationSetting("provider.{id}.customHeaders", .structured, category: .provider, page: .providerAdvanced,
                                 sizeLimit: customHeadersLimit, defaultValue: .structured(Data()),
                                 defaultSource: .provider, scope: .provider, applyBoundary: .nextInvocation,
                                 sensitivity: .credential, exportPolicy: .alwaysExclude),
            configurationSetting("provider.{id}.proxyMode", .string, category: .provider, page: .providerAdvanced,
                                 allowedValues: ["system", "direct", "custom"], defaultValue: .string("system"),
                                 defaultSource: .provider, scope: .provider, applyBoundary: .nextInvocation),
            configurationSetting("provider.{id}.customProxyURL", .string, category: .provider, page: .providerAdvanced,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider,
                                 applyBoundary: .nextInvocation, sensitivity: .sensitive,
                                 exportPolicy: .includeRedacted),
            configurationSetting("provider.{id}.customCAReference", .string, category: .provider, page: .providerAdvanced,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider,
                                 applyBoundary: .nextInvocation, sensitivity: .sensitive,
                                 exportPolicy: .alwaysExclude),
            configurationSetting("provider.{id}.allowInsecureLANHTTP", .bool, category: .provider, page: .providerAdvanced,
                                 defaultValue: .bool(false), defaultSource: .provider, scope: .provider,
                                 applyBoundary: .nextInvocation, sensitivity: .sensitive,
                                 exportPolicy: .includeRedacted),
            configurationSetting("provider.{id}.websiteActionOverrides", .structured, category: .provider, page: .providerDetails,
                                 sizeLimit: websiteActionsLimit, defaultValue: .structured(Data()),
                                 defaultSource: .provider, scope: .provider),

            // codingPlan.{id}.* (12)
            configurationSetting("codingPlan.{id}.displayName", .string, category: .codingPlan, page: .codingPlan,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.enabled", .bool, category: .codingPlan, page: .codingPlan,
                                 defaultValue: .bool(false), defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.baseURL", .string, category: .codingPlan, page: .codingPlan,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider,
                                 sensitivity: .sensitive, exportPolicy: .includeRedacted),
            configurationSetting("codingPlan.{id}.protocol", .string, category: .codingPlan, page: .codingPlan,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.enabledModelIDs", .stringArray, category: .codingPlan, page: .codingPlan,
                                 sizeLimit: modelCollectionLimit, defaultValue: .stringArray([]),
                                 defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.defaultModelID", .string, category: .codingPlan, page: .codingPlan,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.modelCapabilityOverrides", .structured, category: .codingPlan, page: .codingPlan,
                                 sizeLimit: modelCollectionLimit, defaultValue: .structured(Data()),
                                 defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.selectedCompatibilityID", .string, category: .codingPlan, page: .codingPlan,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.selectedLocalAgentConfigurationID", .string, category: .codingPlan, page: .codingPlan,
                                 defaultValue: .string(""), defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.networkPolicy", .structured, category: .codingPlan, page: .codingPlan,
                                 sizeLimit: SettingSizeLimit(maxTotalBytes: 64 * 1_024), defaultValue: .structured(Data()),
                                 defaultSource: .provider, scope: .provider),
            configurationSetting("codingPlan.{id}.customHeaders", .structured, category: .codingPlan, page: .codingPlan,
                                 sizeLimit: customHeadersLimit, defaultValue: .structured(Data()),
                                 defaultSource: .provider, scope: .provider, applyBoundary: .nextInvocation,
                                 sensitivity: .credential, exportPolicy: .alwaysExclude),
            configurationSetting("codingPlan.{id}.websiteActionOverrides", .structured, category: .codingPlan, page: .codingPlan,
                                 sizeLimit: websiteActionsLimit, defaultValue: .structured(Data()),
                                 defaultSource: .provider, scope: .provider),

            // localAgent.{id}.* (12)
            configurationSetting("localAgent.{id}.displayName", .string, category: .localAgent, page: .localAgent,
                                 defaultValue: .string(""), defaultSource: .localAgent, scope: .localAgent),
            configurationSetting("localAgent.{id}.enabled", .bool, category: .localAgent, page: .localAgent,
                                 defaultValue: .bool(false), defaultSource: .localAgent, scope: .localAgent),
            configurationSetting("localAgent.{id}.executionProfileID", .string, category: .localAgent, page: .localAgent,
                                 defaultValue: .string(""), defaultSource: .localAgent, scope: .localAgent),
            configurationSetting("localAgent.{id}.executableReference", .string, category: .localAgent, page: .localAgent,
                                 defaultValue: .string(""), defaultSource: .localAgent, scope: .localAgent,
                                 sensitivity: .sensitive, exportPolicy: .alwaysExclude,
                                 writeOperationKind: .localAgentMaintenanceLaunch),
            configurationSetting("localAgent.{id}.workingDirectoryMode", .string, category: .localAgent, page: .localAgent,
                                 allowedValues: ["sessionTarget", "userSpecified", "askEveryTime"],
                                 defaultValue: .string("sessionTarget"), defaultSource: .localAgent, scope: .localAgent),
            configurationSetting("localAgent.{id}.workingDirectoryReference", .string, category: .localAgent, page: .localAgent,
                                 defaultValue: .string(""), defaultSource: .localAgent, scope: .localAgent,
                                 sensitivity: .sensitive, exportPolicy: .alwaysExclude),
            configurationSetting("localAgent.{id}.pathPolicy", .string, category: .localAgent, page: .localAgent,
                                 allowedValues: ["controlled", "loginShell", "custom"],
                                 defaultValue: .string("controlled"), defaultSource: .localAgent, scope: .localAgent),
            configurationSetting("localAgent.{id}.customPATHEntries", .stringArray, category: .localAgent, page: .localAgent,
                                 sizeLimit: SettingSizeLimit(maxCount: 64), defaultValue: .stringArray([]),
                                 defaultSource: .localAgent, scope: .localAgent,
                                 sensitivity: .sensitive, exportPolicy: .alwaysExclude),
            configurationSetting("localAgent.{id}.environmentAllowlist", .stringArray, category: .localAgent, page: .localAgent,
                                 sizeLimit: SettingSizeLimit(maxCount: 128), defaultValue: .stringArray([]),
                                 defaultSource: .localAgent, scope: .localAgent,
                                 sensitivity: .sensitive, exportPolicy: .alwaysExclude),
            configurationSetting("localAgent.{id}.enabledModelIDs", .stringArray, category: .localAgent, page: .localAgent,
                                 sizeLimit: modelCollectionLimit, defaultValue: .stringArray([]),
                                 defaultSource: .localAgent, scope: .localAgent),
            configurationSetting("localAgent.{id}.defaultModelID", .string, category: .localAgent, page: .localAgent,
                                 defaultValue: .string(""), defaultSource: .localAgent, scope: .localAgent),
            configurationSetting("localAgent.{id}.websiteActionOverrides", .structured, category: .localAgent, page: .localAgent,
                                 sizeLimit: websiteActionsLimit, defaultValue: .structured(Data()),
                                 defaultSource: .localAgent, scope: .localAgent),

            // 内容、隐私、存储和外观 (24)
            setting("assistant.tools.enabledToolIDs", .stringArray, category: .content, page: .toolsAndCapabilities,
                    sizeLimit: SettingSizeLimit(maxCount: 512, maxItemBytes: 512),
                    defaultValue: .stringArray([StacioBuiltinToolID.terminalCommand]), applyBoundary: .nextAttempt,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.instructions.globalText", .string, category: .content, page: .instructionsAndProjectRules,
                    sizeLimit: SettingSizeLimit(maxLengthChars: 256 * 1_024), defaultValue: .string(""),
                    applyBoundary: .nextAttempt, sensitivity: .sensitive,
                    exportPolicy: .alwaysExclude, defaultExportSelection: false),
            setting("assistant.instructions.projectDiscovery", .string, category: .content, page: .instructionsAndProjectRules,
                    allowedValues: ["off", "askBeforeAdding", "approvedRoots"],
                    defaultValue: .string("askBeforeAdding"), applyBoundary: .nextAttempt,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.instructions.approvedRootReferences", .stringArray, category: .content,
                    page: .instructionsAndProjectRules, sizeLimit: SettingSizeLimit(maxCount: 128),
                    defaultValue: .stringArray([]), applyBoundary: .nextAttempt,
                    sensitivity: .sensitive, exportPolicy: .alwaysExclude, defaultExportSelection: false),
            setting("assistant.context.defaultOptionalSourceIDs", .stringArray, category: .content, page: .context,
                    sizeLimit: SettingSizeLimit(maxCount: 128, maxItemBytes: 512),
                    defaultValue: .stringArray([]), applyBoundary: .nextAttempt,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.context.terminalOutputMode", .string, category: .content, page: .context,
                    allowedValues: ["boundedHeadTail", "summaryOnly", "excluded"],
                    defaultValue: .string("boundedHeadTail"), applyBoundary: .nextAttempt,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.context.maxSingleSourceMiB", .int, category: .content, page: .context,
                    range: 1...25, defaultValue: .int(10), applyBoundary: .nextAttempt),
            setting("assistant.context.budgetMode", .string, category: .content, page: .context,
                    allowedValues: ["runtimeReported", "conservativeAutomatic"],
                    defaultValue: .string("runtimeReported"), applyBoundary: .nextAttempt),
            setting("assistant.context.autoCompression", .bool, category: .content, page: .context,
                    defaultValue: .bool(true), applyBoundary: .nextAttempt),
            setting("assistant.memory.projectEnabled", .bool, category: .content, page: .memoryAndHistory,
                    defaultValue: .bool(false), applyBoundary: .nextSession,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.history.retention", .int, category: .storage, page: .memoryAndHistory,
                    range: 1...3_650, defaultValue: .int(30), applyBoundary: .nextSession,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false,
                    writeControlPolicy: .actionOnly, writeOperationKind: .configurationMutation),
            setting("assistant.storage.databaseGiB", .int, category: .storage, page: .storageAndQuota,
                    range: 1...100, defaultValue: .int(1), applyBoundary: .nextSession),
            setting("assistant.storage.attachmentsGiB", .int, category: .storage, page: .storageAndQuota,
                    range: 1...500, defaultValue: .int(2), applyBoundary: .nextSession),
            setting("assistant.storage.terminalLogsGiB", .int, category: .storage, page: .storageAndQuota,
                    range: 1...500, defaultValue: .int(2), applyBoundary: .nextSession),
            setting("assistant.storage.singleAttachmentMiB", .int, category: .storage, page: .storageAndQuota,
                    range: 1...1_024, defaultValue: .int(100), applyBoundary: .nextSession),
            setting("assistant.storage.singleExecutionLogMiB", .int, category: .storage, page: .storageAndQuota,
                    range: 1...1_024, defaultValue: .int(100), applyBoundary: .nextSession),
            setting("assistant.notifications.eventIDs", .stringArray, category: .general, page: .notifications,
                    sizeLimit: SettingSizeLimit(maxCount: 64, maxItemBytes: 128),
                    defaultValue: .stringArray([
                        "attemptCompleted", "attemptFailed", "capacityGrantedAfterLongWait",
                        "approvalRequired", "userInputRequired", "credentialRevoked",
                        "orphanedRuntime", "externalEffectStateUnknown"
                    ]), applyBoundary: .nextTurn),
            setting("assistant.notifications.longCapacityWaitMinutes", .int, category: .general, page: .notifications,
                    range: 1...30, defaultValue: .int(5), applyBoundary: .nextTurn),
            setting("assistant.privacy.telemetryEnabled", .bool, category: .privacy, page: .privacy,
                    defaultValue: .bool(false), applyBoundary: .nextSession,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false,
                    writeControlPolicy: .actionOnly, writeOperationKind: .configurationMutation),
            setting("assistant.privacy.terminalRecordingScope", .string, category: .privacy, page: .privacy,
                    allowedValues: ["none", "bounded", "fullWhenAudited"],
                    defaultValue: .string("bounded"), applyBoundary: .nextAttempt,
                    sensitivity: .privateValue, exportPolicy: .includeRedacted, defaultExportSelection: false),
            setting("assistant.appearance.timelineDensity", .string, category: .appearance,
                    page: .appearanceAndAccessibility, allowedValues: ["compact", "comfortable"],
                    defaultValue: .string("comfortable"), applyBoundary: .nextSession),
            setting("assistant.appearance.codeFontSize", .int, category: .appearance,
                    page: .appearanceAndAccessibility, range: 9...24, defaultValue: .int(13),
                    applyBoundary: .nextSession),
            setting("assistant.appearance.terminalBlockHeight", .int, category: .appearance,
                    page: .appearanceAndAccessibility, range: 120...1_200, defaultValue: .int(320),
                    applyBoundary: .nextSession),
            setting("assistant.appearance.motionMode", .string, category: .appearance,
                    page: .appearanceAndAccessibility, allowedValues: ["system", "reduced"],
                    defaultValue: .string("system"), applyBoundary: .nextSession)
        ]
        return try build(descriptors: descriptors, revision: 2)
    }
}
