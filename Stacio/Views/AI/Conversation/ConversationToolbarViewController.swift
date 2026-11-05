import AppKit
import Foundation

// MARK: - Conversation Toolbar（P6-5）

public enum ConversationToolbarAction {

    /// 工具栏只保留：会话标题/始终可见目标身份/Native 或 Local Agent 状态/新建/搜索/历史/更多。
    public static func toolbarItemIdentifiers() -> [String] {
        ["sessionTitle", "targetIdentity", "runtimeStatus", "newConversation", "search", "history", "more"]
    }

    /// 主机/用户/端口/工作目录变化显示内联状态条（不用遮挡弹窗）。
    public static func identityChangeShowsInlineStatusBar() -> Bool { true }
}

// MARK: - Native conversation toolbar

@MainActor
public final class ConversationToolbarViewController: NSViewController {
    public var onNewConversation: (() -> Void)? {
        didSet { refreshAvailableActions() }
    }
    public var onSearch: (() -> Void)? {
        didSet { refreshAvailableActions() }
    }
    public var onHistory: (() -> Void)? {
        didSet { refreshAvailableActions() }
    }
    public var onTarget: (() -> Void)? {
        didSet { refreshAvailableActions() }
    }
    public var onRename: (() -> Void)? {
        didSet { refreshAvailableActions() }
    }
    public var onArchive: (() -> Void)? {
        didSet { refreshAvailableActions() }
    }
    public var onSettings: (() -> Void)? {
        didSet { refreshAvailableActions() }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let targetButton = NSButton()
    private let runtimeStatusLabel = NSTextField(labelWithString: "")
    private let statusImage = NSImageView()
    private let contentStack = NSStackView()
    private let primaryRow = NSView()
    private let leadingStack = NSStackView()
    private let trailingStack = NSStackView()
    private let newButton = NSButton()
    private let searchButton = NSButton()
    private let historyButton = NSButton()
    private let moreButton = NSButton()
    private let identityChangeLabel = NSTextField(labelWithString: "")
    private var identityStatusWorkItem: DispatchWorkItem?

    public override func loadView() {
        let surface = GlassCapabilityAdapter.makeInteractiveSurface(
            frame: NSRect(x: 0, y: 0, width: 720, height: 46),
            fallbackMaterial: .headerView
        )
        surface.setAccessibilityIdentifier("Stacio.AI.conversationToolbar")
        view = surface
        setupView()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        titleLabel.isHidden = view.bounds.width < 540
    }

    public func configure(
        title: String,
        targetIdentity: String,
        runtimeStatus: String,
        statusSymbol: String = "circle.fill"
    ) {
        titleLabel.stringValue = title
        targetButton.title = targetIdentity
        targetButton.toolTip = targetIdentity
        runtimeStatusLabel.stringValue = runtimeStatus
        runtimeStatusLabel.toolTip = runtimeStatus
        statusImage.image = NSImage(systemSymbolName: statusSymbol, accessibilityDescription: runtimeStatus)
    }

    public func showIdentityChange(_ message: String) {
        identityStatusWorkItem?.cancel()
        identityChangeLabel.stringValue = message
        identityChangeLabel.toolTip = message
        identityChangeLabel.isHidden = false
        let item = DispatchWorkItem { [weak self] in
            self?.identityChangeLabel.isHidden = true
        }
        identityStatusWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    /// 关闭工具栏拥有的 transient popover（例如 Target picker）。Escape
    /// 从 Composer 触发时只调用这一层，不会折叠会话或停止运行。
    @discardableResult
    public func dismissTransientUI() -> Bool {
        guard let presented = presentedViewControllers?.last else { return false }
        dismiss(presented)
        return true
    }

    public var displayedTargetIdentity: String { targetButton.title }
    public var displayedRuntimeStatus: String { runtimeStatusLabel.stringValue }
    public var displayedIdentityChangeMessage: String? {
        identityChangeLabel.isHidden ? nil : identityChangeLabel.stringValue
    }
    var primaryRowFrameForTesting: NSRect {
        primaryRow.superview?.convert(primaryRow.frame, to: view) ?? .zero
    }
    var identityChangeFrameForTesting: NSRect {
        identityChangeLabel.superview?.convert(identityChangeLabel.frame, to: view) ?? .zero
    }

    /// Target picker is owned by the toolbar so the popover is anchored to the
    /// target control instead of an unrelated workbench view.
    public func presentTargetPicker(
        sessions: [AgentTerminalSessionSummary],
        initiallySelectedRuntimeID: String?,
        onSelect: @escaping (String) -> Bool
    ) {
        let picker = AITargetPickerViewController(
            sessions: sessions,
            initiallySelectedRuntimeIDs: [initiallySelectedRuntimeID].compactMap { $0 }
        )
        picker.onSelectRuntimeID = { [weak self, weak picker] runtimeID in
            guard onSelect(runtimeID) else { return }
            if let picker {
                self?.dismiss(picker)
            }
        }
        present(
            picker,
            asPopoverRelativeTo: targetButton.bounds,
            of: targetButton,
            preferredEdge: .maxY,
            behavior: .transient
        )
    }

    public func presentConversationNavigator(
        _ navigator: ConversationSidebarViewController,
        focusedOnSearch: Bool
    ) {
        if let presented = presentedViewControllers?.last {
            dismiss(presented)
        }
        let anchor = focusedOnSearch ? searchButton : historyButton
        present(
            navigator,
            asPopoverRelativeTo: anchor.bounds,
            of: anchor,
            preferredEdge: .maxY,
            behavior: .transient
        )
    }

    var visibleActionIdentifiersForTesting: [String] {
        [
            newButton.isHidden ? nil : "newConversation",
            searchButton.isHidden ? nil : "search",
            historyButton.isHidden ? nil : "history",
            moreButton.isHidden ? nil : "more"
        ].compactMap { $0 }
    }

    private func setupView() {
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 9
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 5
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        primaryRow.translatesAutoresizingMaskIntoConstraints = false

        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 2
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setAccessibilityIdentifier("Stacio.AI.toolbar.title")

        targetButton.bezelStyle = .inline
        targetButton.isBordered = false
        targetButton.font = .systemFont(ofSize: 12)
        targetButton.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "执行目标")
        targetButton.imagePosition = .imageLeading
        targetButton.target = self
        targetButton.action = #selector(openTarget)
        targetButton.cell?.lineBreakMode = .byTruncatingMiddle
        targetButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        targetButton.setAccessibilityIdentifier("Stacio.AI.toolbar.target")

        statusImage.contentTintColor = .secondaryLabelColor
        statusImage.widthAnchor.constraint(equalToConstant: 10).isActive = true
        runtimeStatusLabel.font = .systemFont(ofSize: 11)
        runtimeStatusLabel.textColor = .secondaryLabelColor
        runtimeStatusLabel.lineBreakMode = .byTruncatingTail
        runtimeStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(newButton, symbol: "plus", tooltip: "新建会话", action: #selector(newConversation))
        configureIconButton(searchButton, symbol: "magnifyingglass", tooltip: "搜索会话", action: #selector(search))
        configureIconButton(historyButton, symbol: "clock.arrow.circlepath", tooltip: "会话历史", action: #selector(history))
        configureIconButton(moreButton, symbol: "ellipsis", tooltip: "更多", action: #selector(showMore(_:)))
        moreButton.menu = makeMoreMenu()

        identityChangeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        identityChangeLabel.textColor = .secondaryLabelColor
        identityChangeLabel.alignment = .center
        identityChangeLabel.lineBreakMode = .byTruncatingTail
        identityChangeLabel.isHidden = true
        identityChangeLabel.setAccessibilityIdentifier("Stacio.AI.toolbar.identityChange")
        identityChangeLabel.setAccessibilityLabel("目标状态")

        [titleLabel, targetButton, statusImage, runtimeStatusLabel].forEach(leadingStack.addArrangedSubview)
        [newButton, searchButton, historyButton, moreButton].forEach(trailingStack.addArrangedSubview)
        primaryRow.addSubview(leadingStack)
        primaryRow.addSubview(trailingStack)
        contentStack.addArrangedSubview(primaryRow)
        contentStack.addArrangedSubview(identityChangeLabel)
        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            primaryRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            leadingStack.leadingAnchor.constraint(equalTo: primaryRow.leadingAnchor, constant: 2),
            leadingStack.centerYAnchor.constraint(equalTo: primaryRow.centerYAnchor),
            leadingStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),
            trailingStack.trailingAnchor.constraint(equalTo: primaryRow.trailingAnchor),
            trailingStack.centerYAnchor.constraint(equalTo: primaryRow.centerYAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 42)
        ])
        refreshAvailableActions()
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        if onRename != nil {
            menu.addItem(withTitle: "重命名", action: #selector(rename), keyEquivalent: "")
        }
        if onArchive != nil {
            menu.addItem(withTitle: "归档", action: #selector(archive), keyEquivalent: "")
        }
        if onSettings != nil {
            if menu.items.isEmpty == false {
                menu.addItem(.separator())
            }
            menu.addItem(withTitle: "排查助手设置…", action: #selector(settings), keyEquivalent: ",")
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func refreshAvailableActions() {
        guard isViewLoaded else { return }
        newButton.isHidden = onNewConversation == nil
        searchButton.isHidden = onSearch == nil
        historyButton.isHidden = onHistory == nil
        targetButton.isEnabled = onTarget != nil
        moreButton.menu = makeMoreMenu()
        moreButton.isHidden = moreButton.menu?.items.isEmpty != false
    }

    @objc private func newConversation() { onNewConversation?() }
    @objc private func search() { onSearch?() }
    @objc private func history() { onHistory?() }
    @objc private func openTarget() { onTarget?() }
    @objc private func rename() { onRename?() }
    @objc private func archive() { onArchive?() }
    @objc private func settings() { onSettings?() }
    @objc private func showMore(_ sender: NSButton) {
        guard let menu = sender.menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}
