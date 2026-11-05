import AppKit
import Foundation

@MainActor
final class AISettingsViewController: NSViewController {
    enum Tab: Int, CaseIterable, Equatable {
        case models
        case localAgent
        case context
        case executionPermissions
        case history

        var title: String {
            switch self {
            case .models:
                return L10n.Settings.aiSettingsTabModels
            case .localAgent:
                return L10n.Settings.aiSettingsTabLocalAgent
            case .context:
                return L10n.Settings.aiSettingsTabContext
            case .executionPermissions:
                return L10n.Settings.aiSettingsTabExecutionPermissions
            case .history:
                return L10n.Settings.aiSettingsTabHistory
            }
        }
    }

    private let providerManager: AIProviderManagementViewController
    private let localAgentView: NSView
    private let contextView: NSView
    private let executionPermissionsView: NSView
    private let historyView: NSView
    private let addProviderSheetFactory: () -> AddAIProviderSheetController

    private let activeTabs: [Tab] = [.models, .localAgent, .context, .executionPermissions, .history]

    private let tabControl = NSSegmentedControl(
        labels: [],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let titleLabel = NSTextField(
        labelWithString: L10n.Settings.aiTroubleshootingAssistant
    )
    private let descriptionLabel = NSTextField(
        wrappingLabelWithString: L10n.Settings.aiTroubleshootingAssistantDescription
    )
    private let contentContainer = NSView()

    private var selectedTab: Tab = .models
    private var activeSheetController: AddAIProviderSheetController?
    private var activeSheetWindow: NSWindow?
    private var presentedSheetCount = 0
    private var lastReloadedProviderID: UUID?

    init(
        providerManager: AIProviderManagementViewController,
        localAgentView: NSView? = nil,
        contextView: NSView,
        executionPermissionsView: NSView,
        historyView: NSView,
        addProviderSheetFactory: @escaping () -> AddAIProviderSheetController
    ) {
        self.providerManager = providerManager
        self.localAgentView = localAgentView ?? Self.makeUnavailableLocalAgentView()
        self.contextView = contextView
        self.executionPermissionsView = executionPermissionsView
        self.historyView = historyView
        self.addProviderSheetFactory = addProviderSheetFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        // 供应商、本地 CLI Agent 和排查助手策略属于同一设置入口；
        // 本地 Agent 页只承载终端透传配置，不暴露通用开发 Agent 能力。
        selectedTab = .models
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        StacioDesignSystem.applyRootSurface(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.ai.tabs")

        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("Stacio.Settings.ai.title")

        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.setAccessibilityIdentifier("Stacio.Settings.ai.description")

        tabControl.segmentCount = activeTabs.count
        for (index, tab) in activeTabs.enumerated() {
            tabControl.setLabel(tab.title, forSegment: index)
        }
        tabControl.selectedSegment = selectedTab.rawValue
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.setAccessibilityIdentifier("Stacio.Settings.aiTabs.control")
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSegmentedControl(tabControl)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.setAccessibilityIdentifier("Stacio.Settings.aiTabs.content")

        root.addSubview(titleLabel)
        root.addSubview(descriptionLabel)
        root.addSubview(tabControl)
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),

            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            tabControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            tabControl.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 14),
            tabControl.widthAnchor.constraint(equalToConstant: 520),
            tabControl.heightAnchor.constraint(equalToConstant: 32),

            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 14),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        addChild(providerManager)
        providerManager.onAddProviderRequested = { [weak self] in
            self?.presentAddProviderSheet()
        }

        root.onEffectiveAppearanceRefresh = { [weak self] in
            self?.providerManager.view.needsDisplay = true
            self?.localAgentView.needsDisplay = true
        }
        view = root
        renderSelectedTab()
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard let tab = Tab(rawValue: sender.selectedSegment) else {
            return
        }
        selectedTab = tab
        renderSelectedTab()
    }

    private func renderSelectedTab() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        let selectedView: NSView
        switch selectedTab {
        case .models:
            selectedView = providerManager.view
        case .localAgent:
            selectedView = localAgentView
        case .context:
            selectedView = makeScrollView(
                content: contextView,
                identifier: "Stacio.Settings.ai.context.scroll"
            )
        case .executionPermissions:
            selectedView = makeScrollView(
                content: executionPermissionsView,
                identifier: "Stacio.Settings.ai.execution.scroll"
            )
        case .history:
            selectedView = makeScrollView(
                content: historyView,
                identifier: "Stacio.Settings.ai.history.scroll"
            )
        }

        selectedView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(selectedView)
        NSLayoutConstraint.activate([
            selectedView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            selectedView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            selectedView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            selectedView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        contentContainer.layoutSubtreeIfNeeded()
    }

    private func makeScrollView(content: NSView, identifier: String) -> NSScrollView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(content)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        scrollView.setAccessibilityIdentifier(identifier)

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            content.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -28)
        ])
        return scrollView
    }

    private func presentAddProviderSheet() {
        let sheetController = addProviderSheetFactory()
        activeSheetController = sheetController
        presentedSheetCount += 1
        sheetController.onSaved = { [weak self, weak sheetController] providerID in
            self?.finishAddProviderSheet(sheetController, providerID: providerID)
        }
        sheetController.onCancel = { [weak self, weak sheetController] in
            self?.dismissAddProviderSheet(sheetController)
        }

        guard let parentWindow = view.window else {
            return
        }
        let sheetWindow = NSWindow(contentViewController: sheetController)
        sheetWindow.title = L10n.Settings.addAIProviderTitle
        sheetWindow.styleMask = [.titled]
        activeSheetWindow = sheetWindow
        parentWindow.beginSheet(sheetWindow)
    }

    private func finishAddProviderSheet(
        _ sheetController: AddAIProviderSheetController?,
        providerID: UUID
    ) {
        lastReloadedProviderID = providerID
        providerManager.reloadFromStoreAsync(selecting: providerID)
        dismissAddProviderSheet(sheetController)
    }

    private func dismissAddProviderSheet(_ sheetController: AddAIProviderSheetController?) {
        guard activeSheetController === sheetController else {
            return
        }
        if let sheetWindow = activeSheetWindow,
           let parent = sheetWindow.sheetParent {
            parent.endSheet(sheetWindow)
        }
        activeSheetController = nil
        activeSheetWindow = nil
    }

    private static func makeUnavailableLocalAgentView() -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.localAgent.unavailable")

        let title = NSTextField(labelWithString: "本地 Agent 配置不可用")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.setAccessibilityIdentifier("Stacio.Settings.localAgent.unavailable.title")

        let detail = NSTextField(
            wrappingLabelWithString: "无法安全装配本地 Agent 配置存储或动作协调器。为保护终端和账号，相关操作已关闭。"
        )
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = StacioDesignSystem.theme.secondaryTextColor
        detail.maximumNumberOfLines = 0
        detail.setAccessibilityIdentifier("Stacio.Settings.localAgent.unavailable.detail")

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        return root
    }
}

extension AISettingsViewController {
    var tabTitlesForTesting: [String] { activeTabs.map(\.title) }
    var selectedTabForTesting: Tab { selectedTab }
    var presentedAddProviderSheetCountForTesting: Int { presentedSheetCount }
    var lastReloadedProviderIDForTesting: UUID? { lastReloadedProviderID }

    func selectTabForTesting(_ tab: Tab) {
        selectedTab = tab
        if isViewLoaded {
            tabControl.selectedSegment = tab.rawValue
            renderSelectedTab()
        }
    }

    func completePresentedAddProviderForTesting(providerID: UUID) {
        finishAddProviderSheet(activeSheetController, providerID: providerID)
    }
}
