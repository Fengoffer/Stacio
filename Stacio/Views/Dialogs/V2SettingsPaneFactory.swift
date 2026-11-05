import AppKit
import Foundation

// MARK: - V2 Settings surface

/// 控件分类：直接 Setting / Action-backed Setting / 命令 / 只读投影。
public enum V2SettingsControlKind: Equatable, Sendable {
    case editableSetting(registryID: String)
    case actionBackedSetting(registryID: String, actionID: String)
    case action(actionID: String)
    case readOnlyProjection(registryID: String, source: String, updatedAt: Date?)
}

public struct V2SettingsControlRegistration: Equatable, Sendable {
    public let controlIdentifier: String
    public let page: AssistantSettingsPage
    public let kind: V2SettingsControlKind

    public init(
        controlIdentifier: String,
        page: AssistantSettingsPage = .general,
        kind: V2SettingsControlKind
    ) {
        self.controlIdentifier = controlIdentifier
        self.page = page
        self.kind = kind
    }
}

public enum V2SettingsWindowError: Error, Equatable {
    case editableControlWithoutRegistryID(String)
    case actionBackedControlMissingOwner(String)
    case sensitiveControlWithoutActionID(String)
    case duplicateControlRegistration(String)
    case controllerOwnedControl(String)
    case readOnlyProjectionMissingMetadata(String)
}

/// Retains action targets and the typed store for the lifetime of the pane.
/// The document view intentionally remains an `NSStackView`: this keeps the
/// settings surface native and lets AppKit handle Dynamic Type/window resizing.
public final class V2SettingsPaneView: NSScrollView {
    public let valueStore: AssistantSettingsValueStore?
    public private(set) var lastActionID: String?
    public private(set) var lastErrorMessage: String?
    private var retainedTargets: [AnyObject] = []
    private var statusLabels: [String: NSTextField] = [:]

    init(valueStore: AssistantSettingsValueStore?, frame: NSRect = .zero) {
        self.valueStore = valueStore
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func retainTarget(_ target: AnyObject) {
        retainedTargets.append(target)
    }

    func registerStatusLabel(_ label: NSTextField, for identifier: String) {
        statusLabels[identifier] = label
    }

    func showError(_ message: String, for identifier: String) {
        lastErrorMessage = message
        statusLabels[identifier]?.stringValue = message
        statusLabels[identifier]?.textColor = .systemRed
    }

    func showPending(for identifier: String) {
        lastErrorMessage = nil
        statusLabels[identifier]?.stringValue = "处理中..."
        statusLabels[identifier]?.textColor = .secondaryLabelColor
    }

    func showSuccess(_ message: String = "已完成", for identifier: String) {
        lastErrorMessage = nil
        statusLabels[identifier]?.stringValue = message
        statusLabels[identifier]?.textColor = .secondaryLabelColor
    }

    func showCancelled(for identifier: String) {
        lastErrorMessage = nil
        statusLabels[identifier]?.stringValue = "已取消"
        statusLabels[identifier]?.textColor = .secondaryLabelColor
    }

    public func statusText(for identifier: String) -> String? {
        statusLabels[identifier]?.stringValue
    }

    func recordAction(_ actionID: String) {
        lastActionID = actionID
    }
}

public typealias V2SettingsActionHandler = (
    String,
    [String: SettingValue],
    @escaping (Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>) -> Void
) -> Void

private final class V2SettingsControlTarget: NSObject {
    private let handler: (NSControl) -> Void

    init(handler: @escaping (NSControl) -> Void) {
        self.handler = handler
    }

    @objc func changed(_ sender: NSControl) {
        handler(sender)
    }
}

/// Registry-driven settings form. There is no label-only placeholder path:
/// every user-writable descriptor gets a native control, action-only entries
/// get a button, and projections are explicitly marked read-only.
public enum V2SettingsPaneFactory {
    /// These Actions remain part of the stable Registry, but require a selected
    /// configuration and therefore belong to an instance editor, not this
    /// parameterless global form.
    private static let instanceScopedActionIDs: Set<String> = [
        "configuration.delete"
    ]

    private static let groups: [(page: AssistantSettingsPage, title: String)] = [
        (.general, "通用"),
        (.providers, "供应商"),
        (.providerDetails, "供应商详情"),
        (.providerAdvanced, "Provider 高级"),
        (.models, "模型"),
        (.codingPlan, "Coding Plan"),
        (.localAgent, "本地 Agent"),
        (.execution, "Agent 执行"),
        (.usageAndCost, "用量与成本"),
        (.toolsAndCapabilities, "工具与能力"),
        (.permissionsAndSecurity, "权限与安全"),
        (.instructionsAndProjectRules, "指令与项目规则"),
        (.context, "上下文"),
        (.memoryAndHistory, "记忆与历史"),
        (.storageAndQuota, "存储与配额"),
        (.notifications, "通知"),
        (.privacy, "隐私"),
        (.appearanceAndAccessibility, "外观与辅助功能"),
        (.advancedDiagnostics, "高级诊断")
    ]

    public static var pageIDs: [AssistantSettingsPage] { groups.map(\.page) }

    /// Action-only Setting 的唯一写入 owner。实例模板在选中具体配置后实例化，
    /// 因此不会在无 configuration ID 的全局表单里伪造可编辑控件。
    public static func actionBinding(for registryID: String) -> String? {
        AssistantSettingsActionBinding.actionID(for: registryID)
    }

    public static func page(forAction actionID: String) -> AssistantSettingsPage {
        if actionID.hasPrefix("provider.") { return actionID.contains("Model") || actionID.contains("Models") ? .models : .providerDetails }
        if actionID.hasPrefix("codingPlan.") { return .codingPlan }
        if actionID.hasPrefix("localAgent.") { return .localAgent }
        if actionID.hasPrefix("context.") { return .context }
        if actionID.hasPrefix("history.") || actionID.hasPrefix("memory.") { return .memoryAndHistory }
        if actionID.hasPrefix("diagnostics.") || actionID == "assistant.resetCaches" || actionID == "assistant.redetectRuntimes" {
            return .advancedDiagnostics
        }
        if actionID.hasPrefix("privacy.") { return .privacy }
        if actionID == "assistant.resetSettingsAndInstructions" { return .general }
        switch actionID {
        case "configuration.createFromCatalog", "configuration.import", "configuration.export",
             "configuration.duplicate", "configuration.delete":
            return .providers
        case "configuration.changeNetworkTrust":
            return .providerAdvanced
        case "configuration.openWebsiteAction":
            return .providerDetails
        default:
            return .providerDetails
        }
    }

    /// Full control registration generated from the standard Registry. The
    /// four projection rows have non-setting sources because they are runtime
    /// observations rather than editable preferences.
    public static func registrations() -> [V2SettingsControlRegistration] {
        guard let registry = try? AssistantSettingRegistry.standard() else { return [] }
        var result: [V2SettingsControlRegistration] = []

        for descriptor in registry.descriptorsByID.values.sorted(by: { $0.id < $1.id }) {
            guard !descriptor.id.contains("{id}") else { continue }
            let identifier = "Stacio.Settings.\(descriptor.id)"
            switch descriptor.writeControlPolicy {
            case .userWritable:
                result.append(.init(
                    controlIdentifier: identifier,
                    page: descriptor.page,
                    kind: .editableSetting(registryID: descriptor.id)
                ))
            case .actionOnly:
                guard let actionID = actionBinding(for: descriptor.id) else { continue }
                result.append(.init(
                    controlIdentifier: identifier,
                    page: descriptor.page,
                    kind: .actionBackedSetting(registryID: descriptor.id, actionID: actionID)
                ))
            case .readOnlyProjection:
                result.append(.init(
                    controlIdentifier: identifier,
                    page: descriptor.page,
                    kind: .readOnlyProjection(
                        registryID: descriptor.id,
                        source: "registryProjection",
                        updatedAt: Date()
                    )
                ))
            }
        }

        let projectionRows: [(String, String, AssistantSettingsPage)] = [
            ("provider.configurationState", "configurationStore", .providers),
            ("provider.connectionState", "connectionVerifier", .providerDetails),
            ("provider.networkTrust", "configurationEvidence", .providerAdvanced),
            ("provider.modelSyncState", "modelCatalogService", .models),
            ("codingPlan.planStatus", "codingPlanCatalog", .codingPlan),
            ("localAgent.loginStatus", "localAgentProcessJournal", .localAgent),
            ("execution.schedulerState", "globalExecutionScheduler", .execution),
            ("usage.pricingRevision", "providerPricingCatalog", .usageAndCost),
            ("tools.catalogRevision", "stacioToolCatalog", .toolsAndCapabilities),
            ("security.policyState", "agentExecutionPolicy", .permissionsAndSecurity),
            ("instructions.priority", "instructionSourceResolver", .instructionsAndProjectRules),
            ("context.snapshotPolicy", "contextSnapshotBuilder", .context),
            ("memory.projectState", "projectMemoryStore", .memoryAndHistory),
            ("storage.quota", "storageMonitor", .storageAndQuota),
            ("notifications.authorization", "notificationCenter", .notifications),
            ("privacy.encryptionState", "conversationEncryption", .privacy),
            ("appearance.accessibilityState", "systemAccessibility", .appearanceAndAccessibility),
            ("diagnostics.catalogSetRevision", "runtimeCatalogSet", .advancedDiagnostics)
        ]
        for (id, source, page) in projectionRows {
            result.append(.init(
                controlIdentifier: "Stacio.Settings.\(id)",
                page: page,
                kind: .readOnlyProjection(registryID: id, source: source, updatedAt: Date())
            ))
        }

        if let actions = try? AssistantSettingsActionRegistry.standard() {
            for actionID in actions.actionsByID.keys.sorted() {
                result.append(.init(
                    controlIdentifier: "Stacio.Settings.action.\(actionID)",
                    page: page(forAction: actionID),
                    kind: .action(actionID: actionID)
                ))
            }
        }
        return result
    }

    public static func validate(registrations: [V2SettingsControlRegistration]) throws {
        var seen: Set<String> = []
        for registration in registrations {
            guard seen.insert(registration.controlIdentifier).inserted else {
                throw V2SettingsWindowError.duplicateControlRegistration(registration.controlIdentifier)
            }
            switch registration.kind {
            case .editableSetting(let registryID):
                guard !registryID.isEmpty else {
                    throw V2SettingsWindowError.editableControlWithoutRegistryID(registration.controlIdentifier)
                }
            case .actionBackedSetting(let registryID, let actionID):
                guard !registryID.isEmpty else {
                    throw V2SettingsWindowError.editableControlWithoutRegistryID(registration.controlIdentifier)
                }
                guard !actionID.isEmpty else {
                    throw V2SettingsWindowError.actionBackedControlMissingOwner(registration.controlIdentifier)
                }
            case .action(let actionID):
                guard !actionID.isEmpty else {
                    throw V2SettingsWindowError.sensitiveControlWithoutActionID(registration.controlIdentifier)
                }
            case .readOnlyProjection(let registryID, let source, let updatedAt):
                guard !registryID.isEmpty, !source.isEmpty, updatedAt != nil else {
                    throw V2SettingsWindowError.readOnlyProjectionMissingMetadata(registration.controlIdentifier)
                }
            }
        }
    }

    public static func detectControllerOwnedControls(
        visibleControlIdentifiers: Set<String>, registrations: [V2SettingsControlRegistration]
    ) -> [String] {
        let registered = Set(registrations.map(\.controlIdentifier))
        return visibleControlIdentifiers.subtracting(registered).sorted()
    }

    public static func makeRegistryDrivenPane(
        registry: AssistantSettingRegistry,
        actionRegistry: AssistantSettingsActionRegistry,
        valueStore: AssistantSettingsValueStore? = nil,
        actionAvailability: ((String) -> Bool)? = nil,
        actionHandler: V2SettingsActionHandler? = nil,
        localAgentSettingsView: NSView? = nil
    ) -> NSView {
        let pane = V2SettingsPaneView(valueStore: valueStore ?? AssistantSettingsValueStore.inMemory(registry: registry))
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.hasVerticalScroller = true
        pane.drawsBackground = false
        pane.setAccessibilityIdentifier("Stacio.Settings.v2Pane")

        let document = NSStackView()
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = 14
        document.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 24, right: 20)
        document.translatesAutoresizingMaskIntoConstraints = false
        document.setAccessibilityIdentifier("Stacio.Settings.v2Pane.groups")
        pane.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: pane.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: pane.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: pane.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: pane.contentView.widthAnchor)
        ])

        let allRegistrations = registrations()
        for group in groups {
            let title = NSTextField(labelWithString: group.title)
            title.font = .boldSystemFont(ofSize: 13)
            title.textColor = .labelColor
            title.setAccessibilityIdentifier("Stacio.Settings.group.\(group.page.rawValue)")
            document.addArrangedSubview(title)

            if group.page == .localAgent, let localAgentSettingsView {
                localAgentSettingsView.translatesAutoresizingMaskIntoConstraints = false
                localAgentSettingsView.setContentHuggingPriority(.defaultLow, for: .horizontal)
                document.addArrangedSubview(localAgentSettingsView)
                localAgentSettingsView.widthAnchor.constraint(
                    equalTo: document.widthAnchor,
                    constant: -40
                ).isActive = true
                continue
            }

            for registration in allRegistrations where registration.page == group.page {
                if case .action(let actionID) = registration.kind,
                   instanceScopedActionIDs.contains(actionID) {
                    continue
                }
                let row = makeRow(
                    registration: registration,
                    registry: registry,
                    actionRegistry: actionRegistry,
                    pane: pane,
                    actionAvailability: actionAvailability,
                    actionHandler: actionHandler
                )
                document.addArrangedSubview(row)
            }
        }
        return pane
    }

    private static func makeRow(
        registration: V2SettingsControlRegistration,
        registry: AssistantSettingRegistry,
        actionRegistry: AssistantSettingsActionRegistry,
        pane: V2SettingsPaneView,
        actionAvailability: ((String) -> Bool)?,
        actionHandler: V2SettingsActionHandler?
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier(registration.controlIdentifier)
        row.setContentHuggingPriority(.defaultLow, for: .vertical)

        let label = NSTextField(labelWithString: title(for: registration, registry: registry))
        label.font = .systemFont(ofSize: 13)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 230).isActive = true
        row.addArrangedSubview(label)

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setContentHuggingPriority(.required, for: .horizontal)
        pane.registerStatusLabel(status, for: registration.controlIdentifier)

        switch registration.kind {
        case .editableSetting(let id):
            let control = makeEditableControl(
                id: id,
                registry: registry,
                pane: pane,
                registration: registration,
                actionAvailability: actionAvailability,
                actionHandler: actionHandler
            )
            row.addArrangedSubview(control)
            row.addArrangedSubview(status)
        case .actionBackedSetting(let id, let actionID):
            let control = makeEditableControl(
                id: id,
                registry: registry,
                pane: pane,
                registration: registration,
                actionID: actionID,
                actionAvailability: actionAvailability,
                actionHandler: actionHandler
            )
            row.addArrangedSubview(control)
            row.addArrangedSubview(status)
        case .action(let actionID):
            guard actionRegistry.action(for: actionID) != nil else { return row }
            let button = NSButton(title: actionTitle(actionID), target: nil, action: nil)
            button.bezelStyle = .rounded
            button.image = NSImage(systemSymbolName: actionSymbol(actionID), accessibilityDescription: actionTitle(actionID))
            button.imagePosition = .imageLeading
            button.setAccessibilityIdentifier(registration.controlIdentifier + ".button")
            button.isEnabled = actionHandler != nil && (actionAvailability?(actionID) ?? true)
            let target = V2SettingsControlTarget { [weak pane, weak button] _ in
                guard let pane else { return }
                pane.recordAction(actionID)
                guard let actionHandler else {
                    pane.showError("此操作当前不可用", for: registration.controlIdentifier)
                    return
                }
                pane.showPending(for: registration.controlIdentifier)
                button?.isEnabled = false
                    actionHandler(actionID, [:]) { result in
                    applyActionResultOnMain(
                        result,
                        pane: pane,
                        identifier: registration.controlIdentifier,
                        button: button,
                        actionAvailability: actionAvailability,
                        actionID: actionID
                    )
                }
            }
            button.target = target
            button.action = #selector(V2SettingsControlTarget.changed(_:))
            pane.retainTarget(target)
            row.addArrangedSubview(button)
            row.addArrangedSubview(status)
        case .readOnlyProjection(let id, let source, let updatedAt):
            let valueLabel = NSTextField(labelWithString: projectionText(id: id, source: source, updatedAt: updatedAt, store: pane.valueStore))
            valueLabel.textColor = .secondaryLabelColor
            valueLabel.lineBreakMode = .byTruncatingTail
            valueLabel.setAccessibilityIdentifier(registration.controlIdentifier + ".value")
            row.addArrangedSubview(valueLabel)
            row.addArrangedSubview(status)
        }
        return row
    }

    private static func makeEditableControl(
        id: String,
        registry: AssistantSettingRegistry,
        pane: V2SettingsPaneView,
        registration: V2SettingsControlRegistration,
        actionID: String? = nil,
        actionAvailability: ((String) -> Bool)?,
        actionHandler: V2SettingsActionHandler?
    ) -> NSControl {
        let descriptor = registry.descriptor(for: id)!
        let current = (try? pane.valueStore?.value(for: id)) ?? descriptor.defaultValue
        let control: NSControl
        switch descriptor.valueType {
        case .bool:
            let toggle = NSSwitch()
            if case .bool(let value) = current { toggle.state = value ? .on : .off }
            control = toggle
        case .string where descriptor.allowedValues != nil:
            let popup = NSPopUpButton()
            popup.addItems(withTitles: descriptor.allowedValues ?? [])
            if case .string(let value) = current { popup.selectItem(withTitle: value) }
            control = popup
        case .int:
            let field = NSTextField()
            field.alignment = .right
            field.controlSize = .small
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            if case .int(let value) = current { field.stringValue = String(value) }
            control = field
        case .double:
            let field = NSTextField()
            field.alignment = .right
            field.controlSize = .small
            field.widthAnchor.constraint(equalToConstant: 120).isActive = true
            if case .double(let value) = current { field.stringValue = String(value) }
            control = field
        case .string, .stringArray, .structured:
            let field = NSTextField()
            field.controlSize = .small
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
            switch current {
            case .string(let value): field.stringValue = value
            case .stringArray(let value): field.stringValue = value.joined(separator: "\n")
            case .structured(let value): field.stringValue = String(data: value, encoding: .utf8) ?? ""
            default: break
            }
            control = field
        }

        control.setAccessibilityIdentifier(registration.controlIdentifier + ".control")
        if let actionID {
            control.isEnabled = actionHandler != nil && (actionAvailability?(actionID) ?? true)
        }
        let target = V2SettingsControlTarget { [weak pane, weak control] sender in
            guard let pane, let control else { return }
            do {
                let value = try settingValue(from: control, descriptor: descriptor)
                guard case .valid = registry.resolve(value: value, for: id) else {
                    throw V2SettingsWindowError.controllerOwnedControl(id)
                }
                if let actionID {
                    guard let actionHandler else {
                        pane.showError("此操作当前不可用", for: registration.controlIdentifier)
                        return
                    }
                    pane.recordAction(actionID)
                    pane.showPending(for: registration.controlIdentifier)
                    control.isEnabled = false
                    actionHandler(
                        actionID,
                        ["settingID": .string(id), "value": value]
                    ) { result in
                        applyActionResultOnMain(
                            result,
                            pane: pane,
                            identifier: registration.controlIdentifier,
                            control: control,
                            actionAvailability: actionAvailability,
                            actionID: actionID
                        )
                    }
                } else {
                    _ = try pane.valueStore?.write(
                        id: id,
                        value: value,
                        scope: descriptor.scope.rawValue,
                        migrationKey: descriptor.migrationKey
                    )
                    pane.showSuccess("已保存", for: registration.controlIdentifier)
                }
            } catch {
                pane.showError("值无效或保存失败", for: registration.controlIdentifier)
            }
        }
        control.target = target
        control.action = #selector(V2SettingsControlTarget.changed(_:))
        pane.retainTarget(target)
        return control
    }

    private static func applyActionResult(
        _ result: Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>,
        pane: V2SettingsPaneView,
        identifier: String
    ) {
        switch result {
        case .success(.succeeded):
            pane.showSuccess(for: identifier)
        case .success(.cancelled):
            pane.showCancelled(for: identifier)
        case .success(.failed(let reasonCode)):
            pane.showError("操作失败（\(reasonCode)）", for: identifier)
        case .success(.reconciliationRequired):
            pane.showError("操作状态待确认", for: identifier)
        case .failure(.missingOwner):
            pane.showError("此操作当前不可用", for: identifier)
        case .failure:
            pane.showError("操作未完成", for: identifier)
        }
    }

    /// Business owners may complete an action synchronously on the main
    /// thread or asynchronously on a worker. Applying an already-main result
    /// synchronously avoids a spurious pending state under a busy run loop;
    /// worker completions still cross to AppKit's main thread exactly once.
    private static func applyActionResultOnMain(
        _ result: Result<AssistantSettingsActionExecutionResult, AssistantSettingsActionError>,
        pane: V2SettingsPaneView,
        identifier: String,
        button: NSButton? = nil,
        control: NSControl? = nil,
        actionAvailability: ((String) -> Bool)?,
        actionID: String
    ) {
        let apply = {
            button?.isEnabled = actionAvailability?(actionID) ?? true
            control?.isEnabled = actionAvailability?(actionID) ?? true
            applyActionResult(result, pane: pane, identifier: identifier)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private static func settingValue(from control: NSControl, descriptor: SettingDescriptor) throws -> SettingValue {
        switch descriptor.valueType {
        case .bool:
            guard let toggle = control as? NSSwitch else { throw V2SettingsWindowError.controllerOwnedControl(descriptor.id) }
            return .bool(toggle.state == .on)
        case .string where descriptor.allowedValues != nil:
            guard let popup = control as? NSPopUpButton, let value = popup.selectedItem?.title else {
                throw V2SettingsWindowError.controllerOwnedControl(descriptor.id)
            }
            return .string(value)
        case .int:
            guard let field = control as? NSTextField, let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw V2SettingsWindowError.controllerOwnedControl(descriptor.id)
            }
            return .int(value)
        case .double:
            guard let field = control as? NSTextField, let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw V2SettingsWindowError.controllerOwnedControl(descriptor.id)
            }
            return .double(value)
        case .string:
            return .string((control as? NSTextField)?.stringValue ?? "")
        case .stringArray:
            let values = (control as? NSTextField)?.stringValue
                .split(whereSeparator: { $0 == "\n" || $0 == "," })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            return .stringArray(values)
        case .structured:
            let text = (control as? NSTextField)?.stringValue ?? ""
            guard let data = text.data(using: .utf8) else { throw V2SettingsWindowError.controllerOwnedControl(descriptor.id) }
            return .structured(data)
        }
    }

    private static func title(for registration: V2SettingsControlRegistration, registry: AssistantSettingRegistry) -> String {
        let id: String
        switch registration.kind {
        case .editableSetting(let value),
             .actionBackedSetting(let value, _),
             .readOnlyProjection(let value, _, _):
            id = value
        case .action(let value): id = value
        }
        let last = id.split(separator: ".").last.map(String.init) ?? id
        let names: [String: String] = [
            "defaultRuntime": "默认 Runtime", "defaultWorkMode": "默认工作方式",
            "defaultReasoningEffort": "默认推理强度", "queueAutoAdvance": "自动处理排队输入",
            "restoreLastConversation": "恢复上次会话", "sendKeyMode": "发送快捷键",
            "localAutoTitle": "本地自动标题", "language": "语言", "configurationOrder": "配置顺序",
            "defaultTerminalMode": "默认终端模式", "maxParallelAttempts": "最大并行 Attempt",
            "capacityWaitMinutes": "容量等待上限（分钟）", "approvalDeadlineMinutes": "审批等待（分钟）",
            "userInputDeadline": "用户输入等待（分钟）", "maxEffectiveMinutes": "有效执行上限（分钟）",
            "maxToolSteps": "工具步骤上限", "maxControlledChildTasks": "受控子任务上限",
            "managedStopGraceSeconds": "停止宽限（秒）", "maxModelInvocations": "模型调用上限",
            "tokenWarningThreshold": "Token 提醒", "hardTokenLimit": "Token 硬上限",
            "costWarning": "费用提醒", "hardCostLimit": "费用硬上限", "approvalLevel": "默认审批级别",
            "enabledToolIDs": "启用的工具", "globalText": "全局指令", "projectDiscovery": "项目规则发现",
            "approvedRootReferences": "已批准项目目录", "defaultOptionalSourceIDs": "默认可选来源",
            "terminalOutputMode": "终端输出模式", "maxSingleSourceMiB": "单来源上限（MiB）",
            "budgetMode": "上下文预算模式", "autoCompression": "自动压缩上下文",
            "projectEnabled": "项目记忆", "retention": "历史保留（天）", "databaseGiB": "会话数据库（GiB）",
            "attachmentsGiB": "附件（GiB）", "terminalLogsGiB": "终端日志（GiB）",
            "singleAttachmentMiB": "单附件（MiB）", "singleExecutionLogMiB": "单次执行日志（MiB）",
            "eventIDs": "通知事件", "longCapacityWaitMinutes": "长等待提醒（分钟）",
            "telemetryEnabled": "遥测", "terminalRecordingScope": "终端记录范围",
            "timelineDensity": "时间线密度", "codeFontSize": "代码字号",
            "terminalBlockHeight": "终端块高度", "motionMode": "动态效果",
            "connectionState": "连接状态", "planStatus": "套餐状态", "loginStatus": "登录状态",
            "quota": "当前配额", "catalogSetRevision": "Catalog Set 版本"
        ]
        return names[last] ?? last
    }

    private static func actionTitle(_ id: String) -> String {
        let names: [String: String] = [
            "configuration.createFromCatalog": "添加配置", "configuration.saveDraft": "保存草稿",
            "configuration.resumeCredentialSetup": "继续凭证设置", "configuration.activate": "启用配置",
            "configuration.delete": "删除配置", "configuration.duplicate": "复制配置",
            "configuration.import": "导入配置", "configuration.export": "导出配置",
            "configuration.openWebsiteAction": "打开官网", "configuration.changeNetworkTrust": "更改网络信任",
            "configuration.copyCredentialToNewOrigin": "复制凭证到新 Origin",
            "configuration.discardCredentialSetup": "放弃凭证设置",
            "provider.restoreOfficialURL": "恢复官方 URL", "provider.manageManualModelIDs": "管理手动模型 ID",
            "provider.saveCredentialAndFetchModels": "保存凭证并获取模型", "provider.fetchModels": "获取模型",
            "provider.testConnection": "测试连接", "provider.rotateCredential": "轮换凭证",
            "provider.revokeCredentialNow": "立即撤销凭证", "provider.saveProxyCredential": "保存代理凭证",
            "provider.clearProxyCredential": "清除代理凭证",
            "codingPlan.restoreOfficialURL": "恢复官方 URL",
            "codingPlan.saveCredentialAndFetchModels": "保存套餐凭证并获取模型",
            "codingPlan.fetchModels": "获取套餐模型", "codingPlan.testConnection": "测试套餐连接",
            "codingPlan.rotateCredential": "轮换套餐凭证", "codingPlan.revokeCredentialNow": "撤销套餐凭证",
            "codingPlan.saveProxyCredential": "保存套餐代理凭证", "codingPlan.clearProxyCredential": "清除套餐代理凭证",
            "localAgent.changeExecutionProfile": "更改执行配置", "localAgent.detect": "检测 CLI",
            "localAgent.login": "登录", "localAgent.logout": "退出登录",
            "localAgent.reconcileProcesses": "对账进程", "localAgent.openUpgrade": "打开升级入口",
            "assistant.redetectRuntimes": "重新检测 Runtime", "assistant.resetSettingsAndInstructions": "重置设置与指令",
            "assistant.resetCaches": "重置缓存", "context.previewOutboundPayload": "预览发送内容",
            "history.exportSelection": "导出所选历史", "history.clearSelection": "清除所选历史",
            "history.deleteAllV2": "删除全部 V2 数据", "history.changeRetention": "更改保留周期",
            "memory.exportProject": "导出项目记忆", "memory.deleteProject": "删除项目记忆",
            "diagnostics.previewBundle": "预览诊断包", "diagnostics.exportBundle": "导出诊断包",
            "privacy.changeTelemetryConsent": "更改遥测授权"
        ]
        return names[id] ?? (id.split(separator: ".").last.map(String.init) ?? id)
    }

    private static func actionSymbol(_ id: String) -> String {
        if id.contains("import") { return "square.and.arrow.down" }
        if id.contains("export") { return "square.and.arrow.up" }
        if id.contains("delete") || id.contains("remove") || id.contains("clear") { return "trash" }
        if id.contains("fetch") || id.contains("redetect") { return "arrow.clockwise" }
        if id.contains("login") || id.contains("open") { return "arrow.up.right" }
        return "gearshape"
    }

    private static func projectionText(
        id: String,
        source: String,
        updatedAt: Date?,
        store: AssistantSettingsValueStore?
    ) -> String {
        if let value = try? store?.value(for: id) {
            return valueDescription(value)
        }
        let timestamp = updatedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "未知"
        return "\(source) · \(timestamp)"
    }

    private static func valueDescription(_ value: SettingValue) -> String {
        switch value {
        case .string(let value): return value.isEmpty ? "未设置" : value
        case .int(let value): return String(value)
        case .bool(let value): return value ? "已开启" : "已关闭"
        case .double(let value): return String(value)
        case .stringArray(let value): return value.isEmpty ? "未设置" : value.joined(separator: ", ")
        case .structured(let value): return value.isEmpty ? "未设置" : "已配置"
        }
    }
}
