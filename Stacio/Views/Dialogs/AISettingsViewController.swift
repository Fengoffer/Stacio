import AppKit
import Foundation

@MainActor
final class AISettingsViewController: NSViewController {
    enum Tab: Int, CaseIterable, Equatable {
        case models
        case context
        case executionPermissions
        case history

        var title: String {
            switch self {
            case .models:
                return L10n.Settings.aiSettingsTabModels
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
    private let contextView: NSView
    private let executionPermissionsView: NSView
    private let historyView: NSView
    private let addProviderSheetFactory: () -> AddAIProviderSheetController

    private let tabControl = NSSegmentedControl(
        labels: Tab.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let contentContainer = NSView()

    private var selectedTab: Tab = .models
    private var activeSheetController: AddAIProviderSheetController?
    private var activeSheetWindow: NSWindow?
    private var presentedSheetCount = 0
    private var lastReloadedProviderID: UUID?

    init(
        providerManager: AIProviderManagementViewController,
        contextView: NSView,
        executionPermissionsView: NSView,
        historyView: NSView,
        addProviderSheetFactory: @escaping () -> AddAIProviderSheetController
    ) {
        self.providerManager = providerManager
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
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 760, height: 600))
        StacioDesignSystem.applyRootSurface(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.ai.tabs")

        tabControl.selectedSegment = selectedTab.rawValue
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.setAccessibilityIdentifier("Stacio.Settings.aiTabs.control")
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSegmentedControl(tabControl)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.setAccessibilityIdentifier("Stacio.Settings.aiTabs.content")

        root.addSubview(tabControl)
        root.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            tabControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            tabControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            tabControl.widthAnchor.constraint(equalToConstant: 420),
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
        try? providerManager.reloadFromStore(selecting: providerID)
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
}

extension AISettingsViewController {
    var tabTitlesForTesting: [String] { Tab.allCases.map(\.title) }
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
