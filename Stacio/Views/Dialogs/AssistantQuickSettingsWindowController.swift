import AppKit

@MainActor
final class AssistantQuickSettingsWindowController: NSWindowController {
    private let valueStore: AssistantSettingsValueStore
    private let mutationCoordinator: AssistantSettingsMutationCoordinator
    private let restoreLastConversation = NSButton(checkboxWithTitle: "打开排查助手时恢复上次会话", target: nil, action: nil)
    private let autoCompression = NSButton(checkboxWithTitle: "自动压缩过长上下文", target: nil, action: nil)
    private let sendKeyMode = NSSegmentedControl(labels: ["回车发送", "⌘↩ 发送"], trackingMode: .selectOne, target: nil, action: nil)
    private let workMode = NSSegmentedControl(labels: ["Agent", "先规划", "仅回答"], trackingMode: .selectOne, target: nil, action: nil)
    private let terminalMode = NSSegmentedControl(labels: ["真实终端", "虚拟终端", "每次询问"], trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "设置会立即保存")

    init(valueStore: AssistantSettingsValueStore, mutationCoordinator: AssistantSettingsMutationCoordinator) {
        self.valueStore = valueStore
        self.mutationCoordinator = mutationCoordinator
        let content = AssistantQuickSettingsViewController(
            restoreLastConversation: restoreLastConversation,
            autoCompression: autoCompression,
            sendKeyMode: sendKeyMode,
            workMode: workMode,
            terminalMode: terminalMode,
            statusLabel: statusLabel,
            valueStore: valueStore,
            mutationCoordinator: mutationCoordinator
        )
        let window = NSWindow(contentViewController: content)
        window.title = "排查助手设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 300))
        super.init(window: window)
        content.onReload = { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func reload() {
        guard let window, let content = window.contentViewController as? AssistantQuickSettingsViewController else { return }
        content.reload()
    }
}

@MainActor
private final class AssistantQuickSettingsViewController: NSViewController {
    private let restoreLastConversation: NSButton
    private let autoCompression: NSButton
    private let sendKeyMode: NSSegmentedControl
    private let workMode: NSSegmentedControl
    private let terminalMode: NSSegmentedControl
    private let statusLabel: NSTextField
    private let valueStore: AssistantSettingsValueStore
    private let mutationCoordinator: AssistantSettingsMutationCoordinator
    var onReload: (() -> Void)?

    init(
        restoreLastConversation: NSButton,
        autoCompression: NSButton,
        sendKeyMode: NSSegmentedControl,
        workMode: NSSegmentedControl,
        terminalMode: NSSegmentedControl,
        statusLabel: NSTextField,
        valueStore: AssistantSettingsValueStore,
        mutationCoordinator: AssistantSettingsMutationCoordinator
    ) {
        self.restoreLastConversation = restoreLastConversation
        self.autoCompression = autoCompression
        self.sendKeyMode = sendKeyMode
        self.workMode = workMode
        self.terminalMode = terminalMode
        self.statusLabel = statusLabel
        self.valueStore = valueStore
        self.mutationCoordinator = mutationCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .withinWindow
        root.state = .followsWindowActiveState
        view = root

        let title = NSTextField(labelWithString: "排查助手设置")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "只保留排查会话中最常用的选项，修改后立即对新会话生效。")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        configureControl(restoreLastConversation, action: #selector(toggleRestore(_:)))
        configureControl(autoCompression, action: #selector(toggleCompression(_:)))
        configureSegmented(sendKeyMode, action: #selector(changeSendKey(_:)))
        configureSegmented(workMode, action: #selector(changeWorkMode(_:)))
        configureSegmented(terminalMode, action: #selector(changeTerminalMode(_:)))

        let stack = NSStackView(views: [
            title,
            subtitle,
            makeRow("工作方式", workMode),
            makeRow("终端模式", terminalMode),
            makeRow("发送快捷键", sendKeyMode),
            restoreLastConversation,
            autoCompression,
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            workMode.widthAnchor.constraint(equalToConstant: 250),
            terminalMode.widthAnchor.constraint(equalToConstant: 250),
            sendKeyMode.widthAnchor.constraint(equalToConstant: 250)
        ])
        reload()
    }

    func reload() {
        restoreLastConversation.state = bool("assistant.general.restoreLastConversation") ? .on : .off
        autoCompression.state = bool("assistant.context.autoCompression") ? .on : .off
        sendKeyMode.selectedSegment = string("assistant.general.sendKeyMode") == "commandReturn" ? 1 : 0
        switch string("assistant.general.defaultWorkMode") {
        case "plan": workMode.selectedSegment = 1
        case "answer": workMode.selectedSegment = 2
        default: workMode.selectedSegment = 0
        }
        switch string("assistant.execution.defaultTerminalMode") {
        case "backgroundVirtualTerminal": terminalMode.selectedSegment = 1
        case "ask": terminalMode.selectedSegment = 2
        default: terminalMode.selectedSegment = 0
        }
    }

    private func makeRow(_ label: String, _ control: NSView) -> NSView {
        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12, weight: .medium)
        labelView.textColor = .secondaryLabelColor
        labelView.alignment = .right
        labelView.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let row = NSStackView(views: [labelView, control])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        return row
    }

    private func configureControl(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureSegmented(_ control: NSSegmentedControl, action: Selector) {
        control.target = self
        control.action = action
        control.segmentDistribution = .fillEqually
    }

    private func bool(_ id: String) -> Bool {
        guard case .bool(let value) = try? valueStore.value(for: id) else { return false }
        return value
    }

    private func string(_ id: String) -> String {
        guard case .string(let value) = try? valueStore.value(for: id) else { return "" }
        return value
    }

    private func write(_ id: String, _ value: SettingValue) {
        statusLabel.stringValue = "正在保存…"
        mutationCoordinator.write(settingID: id, value: value) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusLabel.stringValue = result.isSuccess ? "已保存" : "保存失败，请稍后重试"
            }
        }
    }

    @objc private func toggleRestore(_ sender: NSButton) {
        write("assistant.general.restoreLastConversation", .bool(sender.state == .on))
    }

    @objc private func toggleCompression(_ sender: NSButton) {
        write("assistant.context.autoCompression", .bool(sender.state == .on))
    }

    @objc private func changeSendKey(_ sender: NSSegmentedControl) {
        write("assistant.general.sendKeyMode", .string(sender.selectedSegment == 1 ? "commandReturn" : "return"))
    }

    @objc private func changeWorkMode(_ sender: NSSegmentedControl) {
        let value = ["agent", "plan", "answer"].element(at: sender.selectedSegment) ?? "agent"
        write("assistant.general.defaultWorkMode", .string(value))
    }

    @objc private func changeTerminalMode(_ sender: NSSegmentedControl) {
        let value = ["realTerminal", "backgroundVirtualTerminal", "ask"].element(at: sender.selectedSegment) ?? "realTerminal"
        write("assistant.execution.defaultTerminalMode", .string(value))
    }
}

private extension Array {
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
