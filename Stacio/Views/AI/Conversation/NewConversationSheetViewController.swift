import AppKit
import Foundation

public struct NewConversationTargetOption: Equatable, Sendable {
    public let runtimeID: String
    public let title: String
    public let detail: String?
    public let isCurrent: Bool
    public let isVerified: Bool

    public init(
        runtimeID: String,
        title: String,
        detail: String? = nil,
        isCurrent: Bool = false,
        isVerified: Bool = true
    ) {
        self.runtimeID = runtimeID
        self.title = title
        self.detail = detail
        self.isCurrent = isCurrent
        self.isVerified = isVerified
    }
}

public enum NewConversationRuntimeSelection: Equatable, Sendable {
    case native(configurationID: String)
    case localAgent(configurationID: String)

    public var configurationID: String {
        switch self {
        case .native(let configurationID), .localAgent(let configurationID):
            return configurationID
        }
    }
}

public struct NewConversationRuntimeOption: Equatable, Sendable {
    public let selection: NewConversationRuntimeSelection
    public let title: String
    public let modelAccountStatus: String
    public let isVerified: Bool

    public init(
        selection: NewConversationRuntimeSelection,
        title: String,
        modelAccountStatus: String,
        isVerified: Bool
    ) {
        self.selection = selection
        self.title = title
        self.modelAccountStatus = modelAccountStatus
        self.isVerified = isVerified
    }
}

public struct NewConversationConfiguration: Equatable, Sendable {
    public let targetRuntimeID: String
    public let runtimeSelection: NewConversationRuntimeSelection
    public let workMode: TurnWorkMode
    public let executionChoice: TurnExecutionChoice

    public init(
        targetRuntimeID: String,
        runtimeSelection: NewConversationRuntimeSelection,
        workMode: TurnWorkMode,
        executionChoice: TurnExecutionChoice
    ) {
        self.targetRuntimeID = targetRuntimeID
        self.runtimeSelection = runtimeSelection
        self.workMode = workMode
        self.executionChoice = executionChoice
    }
}

@MainActor
public final class NewConversationSheetViewController: NSViewController {
    public var onCreate: ((NewConversationConfiguration) -> Void)?
    public var onCancel: (() -> Void)?
    public var onOpenSettings: (() -> Void)?

    private let targetOptions: [NewConversationTargetOption]
    private let runtimeOptions: [NewConversationRuntimeOption]
    private let initialTargetRuntimeID: String?
    private let initialRuntimeConfigurationID: String?
    private let initialWorkMode: TurnWorkMode
    private let initialExecutionChoice: TurnExecutionChoice

    private let targetPopup = NSPopUpButton()
    private let runtimePopup = NSPopUpButton()
    private let targetStatusLabel = NSTextField(labelWithString: "")
    private let runtimeStatusLabel = NSTextField(labelWithString: "")
    private let modelAccountLabel = NSTextField(labelWithString: "")
    private let workModeControl = NSSegmentedControl(
        labels: ["Agent", "规划", "仅回答"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let executionControl = NSSegmentedControl(
        labels: ["真实终端", "后台终端", "每次询问"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let workModeStatusLabel = NSTextField(labelWithString: "来源：用户选择 · 已确认")
    private let executionStatusLabel = NSTextField(labelWithString: "来源：用户选择 · 已确认")
    private let createButton = NSButton(title: "创建", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let settingsButton = NSButton(title: "打开设置…", target: nil, action: nil)

    public init(
        targets: [NewConversationTargetOption],
        runtimes: [NewConversationRuntimeOption],
        initialTargetRuntimeID: String?,
        initialRuntimeConfigurationID: String?,
        initialWorkMode: TurnWorkMode,
        initialExecutionChoice: TurnExecutionChoice
    ) {
        self.targetOptions = targets
        self.runtimeOptions = runtimes
        self.initialTargetRuntimeID = initialTargetRuntimeID
        self.initialRuntimeConfigurationID = initialRuntimeConfigurationID
        self.initialWorkMode = initialWorkMode
        self.initialExecutionChoice = initialExecutionChoice
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 560, height: 390)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let surface = GlassCapabilityAdapter.makeInteractiveSurface(
            frame: NSRect(origin: .zero, size: preferredContentSize),
            fallbackMaterial: .windowBackground
        )
        surface.setAccessibilityIdentifier("Stacio.AI.newConversation.sheet")
        view = surface
        buildInterface()
        populateOptions()
        applyInitialSelection()
        refreshSelectionState()
    }

    var selectedConfigurationForTesting: NewConversationConfiguration? {
        selectedConfiguration()
    }

    var isCreateEnabledForTesting: Bool { createButton.isEnabled }
    var displayedTargetStatusForTesting: String { targetStatusLabel.stringValue }
    var displayedRuntimeStatusForTesting: String { runtimeStatusLabel.stringValue }
    var displayedModelAccountStatusForTesting: String { modelAccountLabel.stringValue }

    func selectTargetForTesting(runtimeID: String) {
        selectPopup(targetPopup, representedObject: runtimeID)
        refreshSelectionState()
    }

    func selectRuntimeForTesting(configurationID: String) {
        selectPopup(runtimePopup, representedObject: configurationID)
        refreshSelectionState()
    }

    func submitForTesting() { createConversation() }
    func cancelForTesting() { cancel() }

    private func buildInterface() {
        let title = NSTextField(labelWithString: "新建排查会话")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.setAccessibilityLabel("新建排查会话")

        configurePopup(targetPopup, identifier: "Stacio.AI.newConversation.target")
        configurePopup(runtimePopup, identifier: "Stacio.AI.newConversation.runtime")

        [targetStatusLabel, runtimeStatusLabel, modelAccountLabel,
         workModeStatusLabel, executionStatusLabel].forEach { label in
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }

        workModeControl.target = self
        workModeControl.action = #selector(selectionChanged)
        workModeControl.segmentStyle = .automatic
        workModeControl.setAccessibilityIdentifier("Stacio.AI.newConversation.workMode")
        executionControl.target = self
        executionControl.action = #selector(selectionChanged)
        executionControl.segmentStyle = .automatic
        executionControl.setAccessibilityIdentifier("Stacio.AI.newConversation.execution")

        createButton.target = self
        createButton.action = #selector(createConversation)
        createButton.keyEquivalent = "\r"
        createButton.bezelStyle = .rounded
        createButton.setAccessibilityIdentifier("Stacio.AI.newConversation.create")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.bezelStyle = .inline

        let grid = NSGridView(views: [
            [rowLabel("目标"), rowContent(targetPopup, status: targetStatusLabel)],
            [rowLabel("Runtime / Profile"), rowContent(runtimePopup, status: runtimeStatusLabel)],
            [rowLabel("模型 / 账号"), rowContent(modelAccountLabel, status: settingsButton)],
            [rowLabel("工作方式"), rowContent(workModeControl, status: workModeStatusLabel)],
            [rowLabel("执行终端"), rowContent(executionControl, status: executionStatusLabel)]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 18
        grid.xPlacement = .fill
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [cancelButton, createButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)
        view.addSubview(grid)
        view.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 22),
            buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 20),
            buttonRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .right
        return label
    }

    private func rowContent(_ primary: NSView, status: NSView) -> NSView {
        let stack = NSStackView(views: [primary, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        primary.translatesAutoresizingMaskIntoConstraints = false
        primary.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        return stack
    }

    private func configurePopup(_ popup: NSPopUpButton, identifier: String) {
        popup.target = self
        popup.action = #selector(selectionChanged)
        popup.setAccessibilityIdentifier(identifier)
    }

    private func populateOptions() {
        targetPopup.removeAllItems()
        targetPopup.addItem(withTitle: "请选择目标")
        targetPopup.lastItem?.representedObject = nil
        for option in targetOptions {
            let current = option.isCurrent ? " · 当前" : ""
            targetPopup.addItem(withTitle: option.title + current)
            targetPopup.lastItem?.representedObject = option.runtimeID
            targetPopup.lastItem?.toolTip = option.detail
        }

        runtimePopup.removeAllItems()
        runtimePopup.addItem(withTitle: "请选择 Runtime")
        runtimePopup.lastItem?.representedObject = nil
        for option in runtimeOptions {
            runtimePopup.addItem(withTitle: option.title)
            runtimePopup.lastItem?.representedObject = option.selection.configurationID
            runtimePopup.lastItem?.toolTip = option.modelAccountStatus
        }
    }

    private func applyInitialSelection() {
        if let initialTargetRuntimeID {
            selectPopup(targetPopup, representedObject: initialTargetRuntimeID)
        }
        if let initialRuntimeConfigurationID {
            selectPopup(runtimePopup, representedObject: initialRuntimeConfigurationID)
        }
        workModeControl.selectedSegment = Self.workModeIndex(initialWorkMode)
        executionControl.selectedSegment = Self.executionChoiceIndex(initialExecutionChoice)
    }

    private func selectPopup(_ popup: NSPopUpButton, representedObject: String) {
        guard let index = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? String)?.caseInsensitiveCompare(representedObject) == .orderedSame
        }) else { return }
        popup.selectItem(at: index)
    }

    @objc private func selectionChanged() {
        refreshSelectionState()
    }

    private func refreshSelectionState() {
        let target = selectedTargetOption()
        targetStatusLabel.stringValue = target.map {
            "来源：\($0.isCurrent ? "当前终端" : "已连接终端") · \($0.isVerified ? "已验证" : "未验证")"
        } ?? "未选择 · 未验证"

        let runtime = selectedRuntimeOption()
        runtimeStatusLabel.stringValue = runtime.map {
            "来源：配置目录 · \($0.isVerified ? "已验证" : "未验证")"
        } ?? "未选择 · 未验证"
        modelAccountLabel.stringValue = runtime?.modelAccountStatus ?? "未配置 · 未验证"

        if case .localAgent? = runtime?.selection {
            workModeControl.selectedSegment = Self.workModeIndex(.agent)
            executionControl.selectedSegment = Self.executionChoiceIndex(.realTerminal)
            workModeControl.isEnabled = false
            executionControl.isEnabled = false
            workModeStatusLabel.stringValue = "来源：Local Agent Profile · 已确认"
            executionStatusLabel.stringValue = "来源：终端透传 · 已确认"
        } else {
            workModeControl.isEnabled = true
            executionControl.isEnabled = true
            workModeStatusLabel.stringValue = "来源：用户选择 · 已确认"
            executionStatusLabel.stringValue = "来源：用户选择 · 已确认"
        }

        createButton.isEnabled = target?.isVerified == true && runtime?.isVerified == true
    }

    private func selectedTargetOption() -> NewConversationTargetOption? {
        guard let runtimeID = targetPopup.selectedItem?.representedObject as? String else { return nil }
        return targetOptions.first { $0.runtimeID == runtimeID }
    }

    private func selectedRuntimeOption() -> NewConversationRuntimeOption? {
        guard let configurationID = runtimePopup.selectedItem?.representedObject as? String else { return nil }
        return runtimeOptions.first {
            $0.selection.configurationID.caseInsensitiveCompare(configurationID) == .orderedSame
        }
    }

    private func selectedConfiguration() -> NewConversationConfiguration? {
        guard createButton.isEnabled,
              let target = selectedTargetOption(),
              let runtime = selectedRuntimeOption(),
              let workMode = Self.workMode(at: workModeControl.selectedSegment),
              let executionChoice = Self.executionChoice(at: executionControl.selectedSegment)
        else { return nil }
        return NewConversationConfiguration(
            targetRuntimeID: target.runtimeID,
            runtimeSelection: runtime.selection,
            workMode: workMode,
            executionChoice: executionChoice
        )
    }

    @objc private func createConversation() {
        guard let configuration = selectedConfiguration() else { return }
        presentingViewController?.dismiss(self)
        onCreate?(configuration)
    }

    @objc private func cancel() {
        presentingViewController?.dismiss(self)
        onCancel?()
    }

    @objc private func openSettings() {
        presentingViewController?.dismiss(self)
        onOpenSettings?()
    }

    private static func workModeIndex(_ mode: TurnWorkMode) -> Int {
        switch mode {
        case .agent: return 0
        case .planFirst: return 1
        case .answerOnly: return 2
        }
    }

    private static func workMode(at index: Int) -> TurnWorkMode? {
        switch index {
        case 0: return .agent
        case 1: return .planFirst
        case 2: return .answerOnly
        default: return nil
        }
    }

    private static func executionChoiceIndex(_ choice: TurnExecutionChoice) -> Int {
        switch choice {
        case .realTerminal: return 0
        case .backgroundVirtualTerminal: return 1
        case .ask: return 2
        }
    }

    private static func executionChoice(at index: Int) -> TurnExecutionChoice? {
        switch index {
        case 0: return .realTerminal
        case 1: return .backgroundVirtualTerminal
        case 2: return .ask
        default: return nil
        }
    }
}
