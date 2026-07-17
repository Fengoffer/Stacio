import AppKit
import Foundation

internal typealias AIProviderTaskExecutor = (@escaping () -> Void) -> Void
internal typealias AIProviderDeleteConfirmationHandler = (
    AIProviderConfiguration,
    @escaping () -> Void
) -> Void

internal enum AIProviderCatalogUIState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

internal struct AIProviderSummary: Equatable {
    let id: UUID
    let displayName: String
    let statusText: String
    let enabledModelCount: Int
    let totalModelCount: Int
    let isDefault: Bool
    let isRecommended: Bool
}

internal struct AIProviderModelPresentation: Equatable {
    let lineBreakMode: NSLineBreakMode
    let toolTip: String?
}

private struct AIProviderEditDraft {
    var provider: AIProviderConfiguration
    var hasStoredAPIKey: Bool
}

private enum AIProviderConnectionUIState {
    case idle
    case testing
    case succeeded(String)
    case failed(String)
}

private enum AIProviderMutationImpact {
    case none
    case connection
    case catalogAndConnection
}

private final class UncheckedAIProviderCatalogBox: @unchecked Sendable {
    let value: AIModelCatalogLoading

    init(_ value: AIModelCatalogLoading) {
        self.value = value
    }
}

private final class UncheckedAIProviderConnectionTesterBox: @unchecked Sendable {
    let value: AIAssistantConnectionTesting

    init(_ value: AIAssistantConnectionTesting) {
        self.value = value
    }
}

private final class UncheckedAIProviderTaskBox: @unchecked Sendable {
    let operation: () -> Void

    init(_ operation: @escaping () -> Void) {
        self.operation = operation
    }
}

private final class AIProviderModelActionButton: NSButton {
    var modelSelection: AIModelSelection?
}

@MainActor
final class AIProviderManagementViewController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSSearchFieldDelegate,
    NSTextFieldDelegate
{
    static let maskedAPIKeyPlaceholder = "********"

    var onAddProviderRequested: (() -> Void)?
    var onDeleteProviderConfirmationRequested: AIProviderDeleteConfirmationHandler?

    private let settingsStore: AIProviderSettingsStoring
    private let mutationCoordinator: AIProviderMutationCoordinating
    private let modelCatalogLoader: AIModelCatalogLoading
    private let connectionTester: AIAssistantConnectionTesting
    private let urlOpener: StacioURLOpening
    private let backgroundExecutor: AIProviderTaskExecutor
    private let mainExecutor: AIProviderTaskExecutor
    private let now: () -> Date

    internal private(set) var currentEnvelope: AIProviderSettingsEnvelope = .defaultConfiguration
    internal private(set) var selectedProviderID = BuiltInAIProvider.mozheAPIID
    private var catalogStates: [UUID: AIProviderCatalogUIState] = [:]
    private var catalogRequestTokens: [UUID: UUID] = [:]
    private var connectionStates: [UUID: AIProviderConnectionUIState] = [:]
    private var connectionRequestTokens: [UUID: UUID] = [:]
    private var editDrafts: [UUID: AIProviderEditDraft] = [:]
    private var settingsLoadErrorMessage: String?
    private var configurationMutationErrorMessage: String?
    private var providerSearchQuery = ""
    private var modelSearchQuery = ""
    private var isSynchronizingProviderSelection = false
    private var selectedModelID: String?
    private var isSynchronizingModelSelection = false
    private weak var detailScrollView: NSScrollView?
    private weak var detailDocumentView: NSView?

    private let splitView = NSSplitView()
    private let providerSearchField = NSSearchField()
    private let providerTableView = NSTableView()
    private let addProviderButton = NSButton()
    private let removeProviderButton = NSButton()
    private let moreProviderButton = NSButton()

    private let providerNameLabel = NSTextField(labelWithString: "")
    private let providerStatusLabel = NSTextField(labelWithString: "")
    private let visitWebsiteButton = NSButton()
    private let testConnectionButton = NSButton()
    private let refreshModelsButton = NSButton()
    private let displayNameField = NSTextField()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let revealedAPIKeyField = NSTextField()
    private let toggleAPIKeyVisibilityButton = NSButton()
    private let removeAPIKeyButton = NSButton()
    private let advancedDisclosureButton = NSButton()
    private let advancedStack = NSStackView()
    private let compatibilityProtocolPopup = NSPopUpButton()
    private let retryCountField = NSTextField()
    private let retryCountStepper = NSStepper()
    private let requestTimeoutField = NSTextField()
    private let requestTimeoutStepper = NSStepper()
    private let userAgentField = NSTextField()
    private let modelSearchField = NSSearchField()
    private let modelTableView = NSTableView()
    private let catalogStatusLabel = NSTextField(labelWithString: "")
    private let manualModelField = NSTextField()
    private let addManualModelButton = NSButton()
    private let modelCapabilityStack = NSStackView()
    private let selectedModelCapabilityLabel = NSTextField(labelWithString: "")
    private let catalogContextWindowLabel = NSTextField(labelWithString: "")
    private let manualContextBudgetField = NSTextField()
    private let catalogReasoningEffortsLabel = NSTextField(labelWithString: "")
    private let manualReasoningEffortsControl = NSSegmentedControl()
    private let reasoningEffortPopup = NSPopUpButton()
    private var catalogContextWindowRow: NSView?
    private var manualContextBudgetRow: NSView?
    private var catalogReasoningEffortsRow: NSView?
    private var manualReasoningEffortsRow: NSView?
    private var isAPIKeyRevealed = false

    init(
        settingsStore: AIProviderSettingsStoring,
        mutationCoordinator: AIProviderMutationCoordinating,
        modelCatalogLoader: AIModelCatalogLoading,
        connectionTester: AIAssistantConnectionTesting,
        urlOpener: StacioURLOpening? = nil,
        backgroundExecutor: @escaping AIProviderTaskExecutor = { operation in
            let box = UncheckedAIProviderTaskBox(operation)
            DispatchQueue.global(qos: .userInitiated).async {
                box.operation()
            }
        },
        mainExecutor: @escaping AIProviderTaskExecutor = { operation in
            if Thread.isMainThread {
                operation()
            } else {
                let box = UncheckedAIProviderTaskBox(operation)
                DispatchQueue.main.async {
                    box.operation()
                }
            }
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.mutationCoordinator = mutationCoordinator
        self.modelCatalogLoader = modelCatalogLoader
        self.connectionTester = connectionTester
        self.urlOpener = urlOpener ?? WorkspaceURLOpener()
        self.backgroundExecutor = backgroundExecutor
        self.mainExecutor = mainExecutor
        self.now = now
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
        root.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyRootSurface(root)
        root.setAccessibilityIdentifier("Stacio.Settings.aiProviders.manager")

        configureProviderTable()
        configureModelTable()
        configureControls()

        let leftPane = makeLeftPane()
        let rightPane = makeRightPane()

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setAccessibilityIdentifier("Stacio.Settings.aiProviders.split")
        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(.defaultHigh + 1, forSubviewAt: 0)

        root.addSubview(splitView)
        let leftWidth = leftPane.widthAnchor.constraint(equalToConstant: 248)
        leftWidth.priority = .init(999)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            leftWidth,
            leftPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            leftPane.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            rightPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 440)
        ])

        root.onEffectiveAppearanceRefresh = { [weak self] in
            self?.renderSelectedProvider()
            self?.providerTableView.reloadData()
            self?.modelTableView.reloadData()
        }
        view = root

        do {
            try reloadFromStore(selecting: nil)
        } catch {
            currentEnvelope = .defaultConfiguration
            selectedProviderID = preferredProviderID()
            settingsLoadErrorMessage = actionableMessage(for: error, apiKey: nil)
            providerTableView.reloadData()
            syncProviderTableSelection()
            renderSelectedProvider()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        concealAPIKey()
    }

    func reloadFromStore(selecting requestedProviderID: UUID?) throws {
        configurationMutationErrorMessage = nil
        editDrafts.removeAll()
        catalogStates.removeAll()
        catalogRequestTokens.removeAll()
        connectionStates.removeAll()
        connectionRequestTokens.removeAll()

        do {
            let loaded = AIProviderSettingsNormalizer.normalized(try settingsStore.loadAIProviderSettings())
            currentEnvelope = loaded
            settingsLoadErrorMessage = nil
            reconcileSelectionAfterReload(requestedProviderID)

            _ = draft(for: selectedProviderID)

            providerTableView.reloadData()
            syncProviderTableSelection()
            renderSelectedProvider()
        } catch {
            settingsLoadErrorMessage = actionableMessage(for: error, apiKey: nil)
            reconcileSelectionAfterReload(requestedProviderID)
            providerTableView.reloadData()
            syncProviderTableSelection()
            renderSelectedProvider()
            throw error
        }
    }

    func selectProvider(id: UUID) {
        guard providerExists(id) else { return }
        if selectedProviderID != id {
            selectedModelID = nil
        }
        selectedProviderID = id
        _ = draft(for: id)
        syncProviderTableSelection()
        renderSelectedProvider()
    }

    private func selectModel(id: String) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              visibleModels.contains(where: { $0.id == id })
        else {
            return
        }
        selectedModelID = id
        syncModelTableSelection()
        renderSelectedModelCapabilities(
            provider: providerForDisplay(id: selectedProviderID),
            editable: true
        )
        revealSelectedModelCapabilities()
    }

    var visibleProviderIDsForTesting: [UUID] {
        visibleProviderIDs
    }

    var visibleModelIDsForTesting: [String] {
        visibleModels.map(\.id)
    }

    var providerSummariesForTesting: [AIProviderSummary] {
        visibleProviderIDs.map(providerSummary(for:))
    }

    var visitWebsiteButtonVisibleForTesting: Bool {
        visitWebsiteButton.isHidden == false
    }

    func recommendedBadgeVisibleForTesting(providerID: UUID) -> Bool {
        guard let row = visibleProviderIDs.firstIndex(of: providerID),
              let cell = providerTableView.view(
                  atColumn: 0,
                  row: row,
                  makeIfNecessary: true
              )
        else {
            return false
        }
        let identifier = "Stacio.Settings.aiProviders.recommended.\(providerID.uuidString)"
        return containsView(withAccessibilityIdentifier: identifier, in: cell)
    }

    func openSelectedProviderWebsiteForTesting() {
        openProviderWebsite()
    }

    private func containsView(
        withAccessibilityIdentifier identifier: String,
        in root: NSView
    ) -> Bool {
        if root.accessibilityIdentifier() == identifier {
            return true
        }
        return root.subviews.contains {
            containsView(withAccessibilityIdentifier: identifier, in: $0)
        }
    }

    func setProviderSearchForTesting(_ query: String) {
        providerSearchField.stringValue = query
        applyProviderSearch(query)
    }

    func setModelSearchForTesting(_ query: String) {
        modelSearchField.stringValue = query
        applyModelSearch(query)
    }

    func commitDisplayNameForTesting(_ displayName: String) {
        commitDisplayName(displayName)
    }

    func commitBaseURLForTesting(_ baseURL: String) {
        commitBaseURL(baseURL)
    }

    func commitAPIKeyForTesting(_ apiKey: String) {
        commitAPIKey(apiKey)
    }

    func removeAPIKeyForTesting() {
        removeAPIKey()
    }

    var isAPIKeyRevealedForTesting: Bool {
        isAPIKeyRevealed
    }

    func toggleAPIKeyVisibilityForTesting() {
        toggleAPIKeyVisibility()
    }

    func commitNetworkSettingsForTesting(
        maxRetryCount: Int,
        requestTimeoutSeconds: Int,
        userAgent: String
    ) {
        commitNetworkSettings(
            maxRetryCount: maxRetryCount,
            requestTimeoutSeconds: requestTimeoutSeconds,
            userAgent: userAgent
        )
    }

    func commitCompatibilityProtocolForTesting(_ preference: AICompatibilityProtocolPreference) {
        commitCompatibilityProtocol(preference)
    }

    func setDefaultProviderForTesting() {
        setSelectedProviderAsDefault()
    }

    func setDefaultModelForTesting(_ modelID: String) {
        setDefaultModel(modelID)
    }

    func toggleModelEnabledForTesting(_ modelID: String, enabled: Bool) {
        setModelEnabled(modelID, enabled: enabled)
    }

    func addManualModelForTesting(_ modelID: String) {
        addManualModel(modelID)
    }

    func selectModelForTesting(_ modelID: String) {
        selectModel(id: modelID)
    }

    func deleteSelectedProviderForTesting() {
        performDeleteSelectedProvider()
    }

    func refreshModelsForTesting() {
        refreshSelectedProviderModels()
    }

    func testConnectionForTesting() {
        testSelectedProviderConnection()
    }

    func catalogStateForTesting(providerID: UUID) -> AIProviderCatalogUIState {
        catalogStates[providerID] ?? .idle
    }

    func modelStatusTextForTesting(modelID: String) -> String? {
        providerForDisplay(id: selectedProviderID)?.models
            .first(where: { $0.id == modelID })
            .map(modelStatusText)
    }

    func modelPresentationForTesting(modelID: String) -> AIProviderModelPresentation? {
        guard let row = visibleModels.firstIndex(where: { $0.id == modelID }),
              let view = modelTableView.view(
                  atColumn: 1,
                  row: row,
                  makeIfNecessary: true
              ) as? NSTableCellView,
              let field = view.textField
        else {
            return nil
        }
        return AIProviderModelPresentation(
            lineBreakMode: field.lineBreakMode,
            toolTip: field.toolTip
        )
    }

    func modelActionSelectionsForTesting(modelID: String) -> [AIModelSelection] {
        guard let row = visibleModels.firstIndex(where: { $0.id == modelID }) else {
            return []
        }
        return [0, 3].compactMap { column in
            let cell = modelTableView.view(
                atColumn: column,
                row: row,
                makeIfNecessary: true
            )
            return cell?.subviews
                .compactMap { $0 as? AIProviderModelActionButton }
                .first?
                .modelSelection
        }
    }

    private var visibleProviderIDs: [UUID] {
        let providerIDs = currentEnvelope.aiProviders
            .map(\.id)
            .filter { $0 != BuiltInAIProvider.stacioRulesID }
        let allIDs = providerIDs.contains(BuiltInAIProvider.mozheAPIID)
            ? [BuiltInAIProvider.mozheAPIID] + providerIDs.filter { $0 != BuiltInAIProvider.mozheAPIID }
            : providerIDs
        let query = normalizedSearchQuery(providerSearchQuery)
        guard query.isEmpty == false else { return allIDs }
        return allIDs.filter { id in
            guard let provider = providerForDisplay(id: id) else { return false }
            return displayName(for: provider).localizedCaseInsensitiveContains(query)
                || displayedBaseURL(for: provider).localizedCaseInsensitiveContains(query)
                || provider.profile.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleModels: [AIProviderModelConfiguration] {
        guard let provider = providerForDisplay(id: selectedProviderID) else {
            return []
        }
        let query = normalizedSearchQuery(modelSearchQuery)
        guard query.isEmpty == false else { return provider.models }
        return provider.models.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }

    private func configureProviderTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        column.resizingMask = .autoresizingMask
        providerTableView.addTableColumn(column)
        providerTableView.headerView = nil
        providerTableView.rowHeight = 50
        providerTableView.intercellSpacing = NSSize(width: 0, height: 1)
        providerTableView.style = .sourceList
        providerTableView.selectionHighlightStyle = .regular
        providerTableView.dataSource = self
        providerTableView.delegate = self
        StacioDesignSystem.styleTable(providerTableView)
        providerTableView.setAccessibilityIdentifier("Stacio.Settings.aiProviders.list")
        providerTableView.setAccessibilityLabel("AI 供应商")
    }

    private func configureModelTable() {
        let enabled = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabled.title = "启用"
        enabled.width = 44
        enabled.minWidth = 44
        enabled.maxWidth = 44
        let model = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        model.title = "模型 ID"
        model.width = 220
        model.minWidth = 120
        model.resizingMask = .autoresizingMask
        let status = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        status.title = "状态"
        status.width = 92
        status.minWidth = 80
        let defaultColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("default"))
        defaultColumn.title = "默认"
        defaultColumn.width = 46
        defaultColumn.minWidth = 46
        defaultColumn.maxWidth = 46
        [enabled, model, status, defaultColumn].forEach(modelTableView.addTableColumn)
        modelTableView.rowHeight = 30
        modelTableView.intercellSpacing = NSSize(width: 0, height: 1)
        modelTableView.dataSource = self
        modelTableView.delegate = self
        modelTableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        StacioDesignSystem.styleTable(modelTableView)
        modelTableView.setAccessibilityIdentifier("Stacio.Settings.aiProviders.models")
        modelTableView.setAccessibilityLabel("供应商模型")
    }

    private func configureControls() {
        providerSearchField.placeholderString = "搜索供应商"
        providerSearchField.delegate = self
        providerSearchField.target = self
        providerSearchField.action = #selector(providerSearchChanged(_:))
        providerSearchField.translatesAutoresizingMaskIntoConstraints = false
        providerSearchField.setAccessibilityIdentifier("Stacio.Settings.aiProviders.search")
        StacioDesignSystem.styleSearchField(providerSearchField)

        configureIconButton(
            addProviderButton,
            symbolName: "plus",
            toolTip: "添加供应商",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.add",
            action: #selector(addProviderPressed(_:))
        )
        configureIconButton(
            removeProviderButton,
            symbolName: "minus",
            toolTip: "删除供应商",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.remove",
            action: #selector(removeProviderPressed(_:))
        )
        configureIconButton(
            moreProviderButton,
            symbolName: "ellipsis.circle",
            toolTip: "更多供应商操作",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.more",
            action: #selector(moreProviderPressed(_:))
        )

        providerNameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        providerNameLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        providerNameLabel.lineBreakMode = .byTruncatingTail
        providerNameLabel.maximumNumberOfLines = 1
        providerNameLabel.translatesAutoresizingMaskIntoConstraints = false
        providerNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        providerStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        providerStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        providerStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiProviders.status")

        configureCommandButton(
            visitWebsiteButton,
            title: "访问官网",
            symbolName: "arrow.up.right.square",
            toolTip: "在浏览器中访问 mozheAPI",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.visitWebsite",
            action: #selector(visitWebsitePressed(_:))
        )
        visitWebsiteButton.isHidden = true

        configureCommandButton(
            testConnectionButton,
            title: "测试连接",
            symbolName: "bolt.horizontal.circle",
            toolTip: "测试当前供应商连接",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.testConnection",
            action: #selector(testConnectionPressed(_:))
        )
        configureCommandButton(
            refreshModelsButton,
            title: "获取模型",
            symbolName: "arrow.clockwise",
            toolTip: "获取当前供应商模型目录",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.refreshModels",
            action: #selector(refreshModelsPressed(_:))
        )

        configureTextField(
            displayNameField,
            placeholder: "供应商名称",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.displayName",
            action: #selector(displayNameCommitted(_:))
        )
        configureTextField(
            baseURLField,
            placeholder: "https://api.example.com/v1",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.baseURL",
            action: #selector(baseURLCommitted(_:))
        )
        configureTextField(
            apiKeyField,
            placeholder: "API Key",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.apiKey",
            action: #selector(apiKeyCommitted(_:))
        )
        configureTextField(
            revealedAPIKeyField,
            placeholder: "API Key",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.apiKey.revealed",
            action: #selector(apiKeyCommitted(_:))
        )
        revealedAPIKeyField.isEditable = false
        revealedAPIKeyField.isSelectable = true
        revealedAPIKeyField.isHidden = true
        configureIconButton(
            toggleAPIKeyVisibilityButton,
            symbolName: "eye",
            toolTip: "显示 API Key",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.toggleAPIKeyVisibility",
            action: #selector(toggleAPIKeyVisibilityPressed(_:))
        )
        configureIconButton(
            removeAPIKeyButton,
            symbolName: "key.slash",
            toolTip: "移除 API Key",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.removeAPIKey",
            action: #selector(removeAPIKeyPressed(_:))
        )

        advancedDisclosureButton.title = "高级设置"
        advancedDisclosureButton.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil
        )
        advancedDisclosureButton.imagePosition = .imageLeading
        advancedDisclosureButton.alignment = .left
        advancedDisclosureButton.isBordered = false
        advancedDisclosureButton.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        advancedDisclosureButton.target = self
        advancedDisclosureButton.action = #selector(toggleAdvancedSettings(_:))
        advancedDisclosureButton.translatesAutoresizingMaskIntoConstraints = false
        advancedDisclosureButton.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.advancedDisclosure"
        )
        advancedDisclosureButton.setAccessibilityLabel("展开高级设置")

        compatibilityProtocolPopup.addItems(withTitles: ["Chat Completions", "Responses"])
        compatibilityProtocolPopup.target = self
        compatibilityProtocolPopup.action = #selector(compatibilityProtocolChanged(_:))
        compatibilityProtocolPopup.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePopupButton(compatibilityProtocolPopup)

        configureIntegerField(retryCountField, accessibilityLabel: "重试次数")
        retryCountField.target = self
        retryCountField.action = #selector(networkSettingsCommitted(_:))
        configureStepper(
            retryCountStepper,
            minimum: 0,
            maximum: 5,
            action: #selector(retryStepperChanged(_:))
        )
        configureIntegerField(requestTimeoutField, accessibilityLabel: "请求超时秒数")
        requestTimeoutField.target = self
        requestTimeoutField.action = #selector(networkSettingsCommitted(_:))
        configureStepper(
            requestTimeoutStepper,
            minimum: 5,
            maximum: 120,
            action: #selector(timeoutStepperChanged(_:))
        )
        configureTextField(
            userAgentField,
            placeholder: "Stacio",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.userAgent",
            action: #selector(networkSettingsCommitted(_:))
        )

        modelSearchField.placeholderString = "搜索模型"
        modelSearchField.delegate = self
        modelSearchField.target = self
        modelSearchField.action = #selector(modelSearchChanged(_:))
        modelSearchField.translatesAutoresizingMaskIntoConstraints = false
        modelSearchField.setAccessibilityIdentifier("Stacio.Settings.aiProviders.modelSearch")
        StacioDesignSystem.styleSearchField(modelSearchField)

        catalogStatusLabel.font = .systemFont(ofSize: 11)
        catalogStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        catalogStatusLabel.lineBreakMode = .byTruncatingTail
        catalogStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        catalogStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiProviders.catalogStatus")

        configureTextField(
            manualModelField,
            placeholder: "手动添加模型 ID",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.manualModel",
            action: #selector(addManualModelPressed(_:))
        )
        configureIconButton(
            addManualModelButton,
            symbolName: "plus",
            toolTip: "手动添加模型",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.addManualModel",
            action: #selector(addManualModelPressed(_:))
        )

        selectedModelCapabilityLabel.font = .systemFont(ofSize: 11, weight: .medium)
        selectedModelCapabilityLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        selectedModelCapabilityLabel.lineBreakMode = .byTruncatingMiddle
        selectedModelCapabilityLabel.maximumNumberOfLines = 1
        selectedModelCapabilityLabel.translatesAutoresizingMaskIntoConstraints = false
        selectedModelCapabilityLabel.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.model"
        )

        [catalogContextWindowLabel, catalogReasoningEffortsLabel].forEach { label in
            label.font = .systemFont(ofSize: 11)
            label.textColor = StacioDesignSystem.theme.secondaryTextColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        catalogContextWindowLabel.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.catalogContextWindow"
        )
        catalogReasoningEffortsLabel.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.catalogReasoningEfforts"
        )

        configureTextField(
            manualContextBudgetField,
            placeholder: "12000",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.modelCapabilities.manualContextBudget",
            action: #selector(manualContextBudgetCommitted(_:))
        )
        manualContextBudgetField.setAccessibilityLabel("请求上下文预算")

        manualReasoningEffortsControl.segmentCount = AIReasoningEffortPreference.allCases.count
        manualReasoningEffortsControl.trackingMode = .selectAny
        for (index, effort) in AIReasoningEffortPreference.allCases.enumerated() {
            manualReasoningEffortsControl.setLabel(reasoningEffortTitle(effort), forSegment: index)
            manualReasoningEffortsControl.setToolTip(
                "支持 \(reasoningEffortTitle(effort)) 推理强度",
                forSegment: index
            )
        }
        manualReasoningEffortsControl.target = self
        manualReasoningEffortsControl.action = #selector(manualReasoningEffortsChanged(_:))
        manualReasoningEffortsControl.translatesAutoresizingMaskIntoConstraints = false
        manualReasoningEffortsControl.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.manualReasoningEfforts"
        )
        manualReasoningEffortsControl.setAccessibilityLabel("手动设置支持的推理强度")
        StacioDesignSystem.styleSegmentedControl(manualReasoningEffortsControl)

        reasoningEffortPopup.target = self
        reasoningEffortPopup.action = #selector(reasoningEffortChanged(_:))
        reasoningEffortPopup.translatesAutoresizingMaskIntoConstraints = false
        reasoningEffortPopup.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.reasoningEffort"
        )
        reasoningEffortPopup.setAccessibilityLabel("模型推理强度")
        StacioDesignSystem.stylePopupButton(reasoningEffortPopup)
    }

    private func makeLeftPane() -> NSView {
        let pane = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 248, height: 520))
        pane.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applySidebarSurface(pane)

        let scrollView = NSScrollView()
        scrollView.documentView = providerTableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView(views: [addProviderButton, removeProviderButton, moreProviderButton, NSView()])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(providerSearchField)
        pane.addSubview(scrollView)
        pane.addSubview(toolbar)
        NSLayoutConstraint.activate([
            providerSearchField.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            providerSearchField.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            providerSearchField.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            providerSearchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: providerSearchField.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor, constant: -6),

            toolbar.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            toolbar.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),
            toolbar.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -8),
            toolbar.heightAnchor.constraint(equalToConstant: 30)
        ])
        return pane
    }

    private func makeRightPane() -> NSView {
        let pane = NSView(frame: NSRect(x: 249, y: 0, width: 451, height: 520))
        pane.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyWorkspaceSurface(pane)

        let titleStack = NSStackView(views: [providerNameLabel, providerStatusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let actionStack = NSStackView(views: [visitWebsiteButton, testConnectionButton, refreshModelsButton])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 8
        actionStack.detachesHiddenViews = true
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleStack)
        header.addSubview(actionStack)
        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: actionStack.leadingAnchor, constant: -10),
            actionStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            actionStack.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.hasHorizontalScroller = false
        detailScroll.autohidesScrollers = true
        detailScroll.borderType = .noBorder
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.setAccessibilityIdentifier("Stacio.Settings.aiProviders.detailScroll")

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.setAccessibilityIdentifier("Stacio.Settings.aiProviders.detailDocument")
        detailScroll.documentView = document
        detailScrollView = detailScroll
        detailDocumentView = document
        let content = makeDetailContent()
        content.setAccessibilityIdentifier("Stacio.Settings.aiProviders.detailContent")
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: detailScroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: detailScroll.contentView.heightAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -16)
        ])

        pane.addSubview(header)
        pane.addSubview(separator)
        pane.addSubview(detailScroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            header.topAnchor.constraint(equalTo: pane.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 66),
            separator.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
        ])
        return pane
    }

    private func makeDetailContent() -> NSStackView {
        let basicTitle = makeSectionTitle("基础设置")
        basicTitle.setAccessibilityIdentifier("Stacio.Settings.aiProviders.basicSection")
        let apiKeyControls = NSStackView(
            views: [
                apiKeyField,
                revealedAPIKeyField,
                toggleAPIKeyVisibilityButton,
                removeAPIKeyButton
            ]
        )
        apiKeyControls.orientation = .horizontal
        apiKeyControls.alignment = .centerY
        apiKeyControls.distribution = .fill
        apiKeyControls.spacing = 6
        apiKeyControls.detachesHiddenViews = true
        apiKeyControls.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        revealedAPIKeyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toggleAPIKeyVisibilityButton.setContentHuggingPriority(.required, for: .horizontal)
        removeAPIKeyButton.setContentHuggingPriority(.required, for: .horizontal)

        advancedStack.orientation = .vertical
        advancedStack.alignment = .width
        advancedStack.spacing = 8
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        let compatibilityProtocolRow = makeFormRow(
            label: "协议",
            control: compatibilityProtocolPopup,
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.compatibilityProtocol"
        )
        let retryCountRow = makeFormRow(
            label: "重试次数",
            control: makeNumericControl(field: retryCountField, stepper: retryCountStepper),
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.retryCount"
        )
        let requestTimeoutRow = makeFormRow(
            label: "请求超时",
            control: makeNumericControl(field: requestTimeoutField, stepper: requestTimeoutStepper),
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.requestTimeout"
        )
        let userAgentRow = makeFormRow(
            label: "User-Agent",
            control: userAgentField,
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.userAgent"
        )
        let advancedRows = [
            compatibilityProtocolRow,
            retryCountRow,
            requestTimeoutRow,
            userAgentRow
        ]
        advancedRows.forEach(advancedStack.addArrangedSubview)
        advancedRows.forEach { row in
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: advancedStack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: advancedStack.trailingAnchor)
            ])
        }
        advancedStack.isHidden = true

        let modelTitle = makeSectionTitle("模型")
        let modelTitleRow = NSStackView(views: [modelTitle, NSView(), catalogStatusLabel])
        modelTitleRow.orientation = .horizontal
        modelTitleRow.alignment = .centerY
        modelTitleRow.spacing = 8
        modelTitleRow.translatesAutoresizingMaskIntoConstraints = false
        modelTitleRow.setAccessibilityIdentifier("Stacio.Settings.aiProviders.modelSection")

        let modelScroll = NSScrollView()
        modelScroll.documentView = modelTableView
        modelScroll.hasVerticalScroller = true
        modelScroll.hasHorizontalScroller = false
        modelScroll.autohidesScrollers = true
        modelScroll.borderType = .bezelBorder
        modelScroll.drawsBackground = true
        modelScroll.backgroundColor = StacioDesignSystem.theme.elevatedPanelColor
        modelScroll.translatesAutoresizingMaskIntoConstraints = false
        modelScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true

        let manualAddRow = NSStackView(views: [manualModelField, addManualModelButton])
        manualAddRow.orientation = .horizontal
        manualAddRow.alignment = .centerY
        manualAddRow.spacing = 6
        manualAddRow.translatesAutoresizingMaskIntoConstraints = false

        let capabilityTitle = makeSectionTitle("模型能力")
        capabilityTitle.setAccessibilityIdentifier("Stacio.Settings.aiProviders.modelCapabilities.title")
        let capabilityTitleRow = NSStackView(
            views: [capabilityTitle, NSView(), selectedModelCapabilityLabel]
        )
        capabilityTitleRow.orientation = .horizontal
        capabilityTitleRow.alignment = .centerY
        capabilityTitleRow.spacing = 8
        capabilityTitleRow.translatesAutoresizingMaskIntoConstraints = false

        let catalogContextWindowRow = makeFormRow(
            label: "上下文窗口",
            control: catalogContextWindowLabel
        )
        catalogContextWindowRow.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.catalogContextWindowRow"
        )
        self.catalogContextWindowRow = catalogContextWindowRow
        let manualContextBudgetRow = makeFormRow(
            label: "请求预算",
            control: makeContextBudgetControl()
        )
        manualContextBudgetRow.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.manualContextBudgetRow"
        )
        self.manualContextBudgetRow = manualContextBudgetRow
        let catalogReasoningEffortsRow = makeFormRow(
            label: "支持推理",
            control: catalogReasoningEffortsLabel
        )
        catalogReasoningEffortsRow.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.catalogReasoningEffortsRow"
        )
        self.catalogReasoningEffortsRow = catalogReasoningEffortsRow
        let manualReasoningEffortsRow = makeFormRow(
            label: "支持推理",
            control: manualReasoningEffortsControl
        )
        manualReasoningEffortsRow.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.modelCapabilities.manualReasoningEffortsRow"
        )
        self.manualReasoningEffortsRow = manualReasoningEffortsRow
        let reasoningEffortRow = makeFormRow(
            label: "推理强度",
            control: reasoningEffortPopup
        )

        modelCapabilityStack.orientation = .vertical
        modelCapabilityStack.alignment = .leading
        modelCapabilityStack.spacing = 8
        modelCapabilityStack.detachesHiddenViews = true
        modelCapabilityStack.translatesAutoresizingMaskIntoConstraints = false
        modelCapabilityStack.setAccessibilityIdentifier("Stacio.Settings.aiProviders.modelCapabilities")
        modelCapabilityStack.addArrangedSubview(makeSeparator())
        modelCapabilityStack.addArrangedSubview(capabilityTitleRow)
        modelCapabilityStack.addArrangedSubview(catalogContextWindowRow)
        modelCapabilityStack.addArrangedSubview(manualContextBudgetRow)
        modelCapabilityStack.addArrangedSubview(catalogReasoningEffortsRow)
        modelCapabilityStack.addArrangedSubview(manualReasoningEffortsRow)
        modelCapabilityStack.addArrangedSubview(reasoningEffortRow)
        modelCapabilityStack.isHidden = true

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.detachesHiddenViews = true
        content.translatesAutoresizingMaskIntoConstraints = false
        let displayNameRow = makeFormRow(
            label: "名称",
            control: displayNameField,
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.displayName"
        )
        let baseURLRow = makeFormRow(
            label: "Base URL",
            control: baseURLField,
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.baseURL"
        )
        let apiKeyRow = makeFormRow(
            label: "API Key",
            control: apiKeyControls,
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.apiKey"
        )
        content.addArrangedSubview(basicTitle)
        content.addArrangedSubview(displayNameRow)
        content.addArrangedSubview(baseURLRow)
        content.addArrangedSubview(apiKeyRow)
        content.addArrangedSubview(advancedDisclosureButton)
        content.addArrangedSubview(advancedStack)
        content.addArrangedSubview(makeSeparator())
        content.addArrangedSubview(modelTitleRow)
        content.addArrangedSubview(modelSearchField)
        content.addArrangedSubview(modelScroll)
        content.addArrangedSubview(manualAddRow)
        content.addArrangedSubview(modelCapabilityStack)
        let leftAlignedViews: [NSView] = [
            basicTitle,
            displayNameRow,
            baseURLRow,
            apiKeyRow,
            advancedDisclosureButton,
            advancedStack
        ]
        leftAlignedViews.forEach { child in
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            modelCapabilityStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            modelCapabilityStack.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        return content
    }

    private func makeFormRow(
        label title: String,
        control: NSView,
        accessibilityIdentifier: String? = nil
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        if let accessibilityIdentifier {
            row.setAccessibilityIdentifier(accessibilityIdentifier)
            label.setAccessibilityIdentifier("\(accessibilityIdentifier).label")
        }
        return row
    }

    private func makeNumericControl(field: NSTextField, stepper: NSStepper) -> NSView {
        let spacer = NSView()
        let stack = NSStackView(views: [field, stepper, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        field.setContentHuggingPriority(.required, for: .horizontal)
        stepper.setContentHuggingPriority(.required, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func makeContextBudgetControl() -> NSView {
        let unit = NSTextField(labelWithString: "字符")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = StacioDesignSystem.theme.secondaryTextColor
        unit.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        let stack = NSStackView(views: [manualContextBudgetField, unit, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        manualContextBudgetField.widthAnchor.constraint(equalToConstant: 108).isActive = true
        manualContextBudgetField.setContentHuggingPriority(.required, for: .horizontal)
        unit.setContentHuggingPriority(.required, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func makeSectionTitle(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        field.textColor = StacioDesignSystem.theme.primaryTextColor
        field.alignment = .left
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }

    private func configureTextField(
        _ field: NSTextField,
        placeholder: String,
        accessibilityIdentifier: String,
        action: Selector
    ) {
        field.placeholderString = placeholder
        field.delegate = self
        field.target = self
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        StacioDesignSystem.styleCompactTextField(field)
    }

    private func configureIntegerField(_ field: NSTextField, accessibilityLabel: String) {
        field.delegate = self
        field.alignment = .right
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel(accessibilityLabel)
        StacioDesignSystem.styleCompactTextField(field)
    }

    private func configureStepper(
        _ stepper: NSStepper,
        minimum: Double,
        maximum: Double,
        action: Selector
    ) {
        stepper.minValue = minimum
        stepper.maxValue = maximum
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = action
        stepper.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureIconButton(
        _ button: NSButton,
        symbolName: String,
        toolTip: String,
        accessibilityIdentifier: String,
        action: Selector
    ) {
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        button.title = ""
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(toolTip)
        StacioDesignSystem.styleIconButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func configureCommandButton(
        _ button: NSButton,
        title: String,
        symbolName: String,
        toolTip: String,
        accessibilityIdentifier: String,
        action: Selector
    ) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setAccessibilityLabel(toolTip)
        StacioDesignSystem.styleSheetButton(button)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 94).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === providerTableView {
            return visibleProviderIDs.count
        }
        return visibleModels.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        if tableView === providerTableView {
            guard visibleProviderIDs.indices.contains(row) else { return nil }
            return makeProviderRow(providerSummary(for: visibleProviderIDs[row]))
        }
        guard visibleModels.indices.contains(row), let tableColumn else { return nil }
        return makeModelCell(
            model: visibleModels[row],
            column: tableColumn.identifier.rawValue,
            row: row
        )
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView === providerTableView {
            guard isSynchronizingProviderSelection == false else { return }
            let row = providerTableView.selectedRow
            guard visibleProviderIDs.indices.contains(row) else { return }
            selectProvider(id: visibleProviderIDs[row])
            return
        }
        if tableView === modelTableView {
            guard isSynchronizingModelSelection == false else { return }
            let row = modelTableView.selectedRow
            guard visibleModels.indices.contains(row) else { return }
            selectModel(id: visibleModels[row].id)
        }
    }

    private func makeProviderRow(_ summary: AIProviderSummary) -> NSView {
        let cell = NSTableCellView()
        cell.setAccessibilityIdentifier("Stacio.Settings.aiProviders.provider.\(summary.id.uuidString)")

        let name = NSTextField(labelWithString: summary.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = StacioDesignSystem.theme.primaryTextColor
        name.lineBreakMode = .byTruncatingTail
        name.maximumNumberOfLines = 1
        name.translatesAutoresizingMaskIntoConstraints = false
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [name])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        if summary.isRecommended {
            titleRow.addArrangedSubview(makeRecommendedBadge(providerID: summary.id))
        }

        let metadata = NSTextField(
            labelWithString: "\(summary.statusText) · \(summary.enabledModelCount)/\(summary.totalModelCount) 个模型"
        )
        metadata.font = .systemFont(ofSize: 10.5)
        metadata.textColor = providerStatusColor(for: summary.id)
        metadata.lineBreakMode = .byTruncatingTail
        metadata.maximumNumberOfLines = 1
        metadata.translatesAutoresizingMaskIntoConstraints = false

        let star = NSImageView(
            image: NSImage(
                systemSymbolName: "star.fill",
                accessibilityDescription: "默认供应商"
            ) ?? NSImage()
        )
        star.contentTintColor = StacioDesignSystem.theme.accentColor
        star.isHidden = summary.isDefault == false
        star.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(titleRow)
        cell.addSubview(metadata)
        cell.addSubview(star)
        NSLayoutConstraint.activate([
            titleRow.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: star.leadingAnchor, constant: -6),
            titleRow.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            metadata.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            metadata.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            metadata.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 2),
            star.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            star.centerYAnchor.constraint(equalTo: titleRow.centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 13),
            star.heightAnchor.constraint(equalToConstant: 13)
        ])
        return cell
    }

    private func makeRecommendedBadge(providerID: UUID) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.cornerCurve = .continuous
        container.layer?.borderWidth = 1
        StacioDesignSystem.setLayerBackgroundColor(
            container,
            color: StacioDesignSystem.theme.accentColor.withAlphaComponent(0.12)
        )
        StacioDesignSystem.setLayerBorderColor(
            container,
            color: StacioDesignSystem.theme.accentColor.withAlphaComponent(0.32)
        )
        container.setAccessibilityIdentifier(
            "Stacio.Settings.aiProviders.recommended.\(providerID.uuidString)"
        )
        container.setAccessibilityLabel("推荐供应商")

        let label = NSTextField(labelWithString: "推荐")
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = StacioDesignSystem.theme.accentColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])
        return container
    }

    private func makeModelCell(
        model: AIProviderModelConfiguration,
        column: String,
        row: Int
    ) -> NSView {
        let isReadOnly = providerForDisplay(id: selectedProviderID) == nil
        let selection = AIModelSelection(providerID: selectedProviderID, modelID: model.id)
        switch column {
        case "enabled":
            let checkbox = AIProviderModelActionButton()
            checkbox.setButtonType(.switch)
            checkbox.title = ""
            checkbox.state = model.isEnabled ? .on : .off
            checkbox.modelSelection = selection
            checkbox.target = self
            checkbox.action = #selector(modelEnabledChanged(_:))
            checkbox.isEnabled = isReadOnly == false
            checkbox.setAccessibilityLabel("启用模型 \(model.id)")
            return centeredCell(containing: checkbox)
        case "model":
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: model.id)
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.toolTip = model.id
            label.setAccessibilityLabel(model.id)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        case "status":
            let label = NSTextField(labelWithString: modelStatusText(model))
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = modelStatusColor(model)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = modelStatusText(model)
            label.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        default:
            let isDefault = providerForDisplay(id: selectedProviderID)?.defaultModelID == model.id
            let button = AIProviderModelActionButton()
            button.frame = NSRect(x: 0, y: 0, width: 26, height: 26)
            button.title = ""
            button.image = NSImage(
                systemSymbolName: isDefault ? "star.fill" : "star",
                accessibilityDescription: isDefault ? "默认模型" : "设为默认模型"
            )
            button.imagePosition = .imageOnly
            button.contentTintColor = isDefault
                ? StacioDesignSystem.theme.accentColor
                : StacioDesignSystem.theme.secondaryTextColor
            button.toolTip = isDefault ? "当前默认模型" : "设为默认模型"
            button.modelSelection = selection
            button.target = self
            button.action = #selector(defaultModelPressed(_:))
            button.isBordered = false
            button.isEnabled = isReadOnly == false
            button.setAccessibilityLabel(button.toolTip)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 26),
                button.heightAnchor.constraint(equalToConstant: 26)
            ])
            return centeredCell(containing: button)
        }
    }

    private func centeredCell(containing control: NSView) -> NSView {
        let cell = NSTableCellView()
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === apiKeyField,
              apiKeyField.stringValue == Self.maskedAPIKeyPlaceholder
        else {
            return
        }
        apiKeyField.stringValue = ""
        updateAPIKeyActionAvailability(editable: providerForDisplay(id: selectedProviderID) != nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === providerSearchField {
            applyProviderSearch(field.stringValue)
            return
        }
        if field === modelSearchField {
            applyModelSearch(field.stringValue)
            return
        }
        if field === manualContextBudgetField {
            return
        }
        guard var draft = draft(for: selectedProviderID) else {
            return
        }
        if selectedProviderID == BuiltInAIProvider.mozheAPIID {
            if field === displayNameField {
                field.stringValue = BuiltInAIProvider.mozheAPIDisplayName
                return
            }
            if field === baseURLField {
                field.stringValue = BuiltInAIProvider.mozheAPIBaseURL
                return
            }
        }
        if field === displayNameField {
            draft.provider.displayName = field.stringValue
        } else if field === baseURLField {
            draft.provider.baseURL = field.stringValue
            invalidateRequestsForRequestSensitiveTyping(providerID: selectedProviderID)
        } else if field === apiKeyField {
            invalidateRequestsForRequestSensitiveTyping(providerID: selectedProviderID)
            updateAPIKeyActionAvailability(editable: draft.provider.id == selectedProviderID)
        } else if field === userAgentField {
            draft.provider.userAgent = field.stringValue
            invalidateRequestsForRequestSensitiveTyping(providerID: selectedProviderID)
        } else if field === retryCountField {
            if let value = Int(field.stringValue) {
                draft.provider.maxRetryCount = value
            }
            invalidateRequestsForRequestSensitiveTyping(providerID: selectedProviderID)
        } else if field === requestTimeoutField {
            if let value = Int(field.stringValue) {
                draft.provider.requestTimeoutSeconds = value
            }
            invalidateRequestsForRequestSensitiveTyping(providerID: selectedProviderID)
        }
        editDrafts[selectedProviderID] = draft
        if field === displayNameField {
            providerNameLabel.stringValue = field.stringValue
            providerTableView.reloadData()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === displayNameField {
            commitDisplayName(field.stringValue)
        } else if field === baseURLField {
            commitBaseURL(field.stringValue)
        } else if field === apiKeyField {
            commitAPIKey(field.stringValue)
        } else if field === manualContextBudgetField {
            commitManualContextBudget(field.stringValue)
        } else if field === retryCountField || field === requestTimeoutField || field === userAgentField {
            commitNetworkFields()
        }
    }

    @objc private func providerSearchChanged(_ sender: NSSearchField) {
        applyProviderSearch(sender.stringValue)
    }

    @objc private func modelSearchChanged(_ sender: NSSearchField) {
        applyModelSearch(sender.stringValue)
    }

    private func applyProviderSearch(_ query: String) {
        providerSearchQuery = query
        providerTableView.reloadData()
        syncProviderTableSelection()
    }

    private func applyModelSearch(_ query: String) {
        modelSearchQuery = query
        reconcileSelectedModel()
        modelTableView.reloadData()
        syncModelTableSelection()
        renderSelectedModelCapabilities(
            provider: providerForDisplay(id: selectedProviderID),
            editable: providerForDisplay(id: selectedProviderID) != nil
        )
    }

    @objc private func addProviderPressed(_ sender: NSButton) {
        onAddProviderRequested?()
    }

    @objc private func removeProviderPressed(_ sender: NSButton) {
        guard selectedProviderID != BuiltInAIProvider.mozheAPIID,
              selectedProviderID != BuiltInAIProvider.stacioRulesID,
              let provider = providerForDisplay(id: selectedProviderID)
        else {
            return
        }
        let providerID = provider.id
        let deletion: () -> Void = { [weak self] in
            self?.performDeleteProvider(id: providerID)
        }
        if let onDeleteProviderConfirmationRequested {
            onDeleteProviderConfirmationRequested(provider, deletion)
            return
        }

        let alert = NSAlert()
        alert.messageText = "删除供应商“\(provider.displayName)”？"
        alert.informativeText = "该供应商配置和对应 API Key 将被移除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    deletion()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            deletion()
        }
    }

    @objc private func moreProviderPressed(_ sender: NSButton) {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "设为默认供应商",
            action: #selector(setDefaultProviderMenuItem(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = currentEnvelope.defaultAIProviderID == selectedProviderID ? .on : .off
        menu.addItem(item)
        menu.popUp(positioning: item, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func setDefaultProviderMenuItem(_ sender: NSMenuItem) {
        setSelectedProviderAsDefault()
    }

    @objc private func displayNameCommitted(_ sender: NSTextField) {
        commitDisplayName(sender.stringValue)
    }

    @objc private func baseURLCommitted(_ sender: NSTextField) {
        commitBaseURL(sender.stringValue)
    }

    @objc private func apiKeyCommitted(_ sender: NSTextField) {
        commitAPIKey(sender.stringValue)
    }

    @objc private func removeAPIKeyPressed(_ sender: NSButton) {
        removeAPIKey()
    }

    @objc private func toggleAPIKeyVisibilityPressed(_ sender: NSButton) {
        endPendingTextEditing()
        toggleAPIKeyVisibility()
    }

    @objc private func toggleAdvancedSettings(_ sender: NSButton) {
        advancedStack.isHidden.toggle()
        let expanded = advancedStack.isHidden == false
        advancedDisclosureButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        advancedDisclosureButton.setAccessibilityLabel(expanded ? "收起高级设置" : "展开高级设置")
    }

    @objc private func compatibilityProtocolChanged(_ sender: NSPopUpButton) {
        let preference: AICompatibilityProtocolPreference = sender.indexOfSelectedItem == 1
            ? .responses
            : .chatCompletions
        commitCompatibilityProtocol(preference)
    }

    @objc private func manualContextBudgetCommitted(_ sender: NSTextField) {
        commitManualContextBudget(sender.stringValue)
    }

    @objc private func manualReasoningEffortsChanged(_ sender: NSSegmentedControl) {
        commitManualReasoningEfforts()
    }

    @objc private func reasoningEffortChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let effort = AIReasoningEffortPreference(rawValue: rawValue)
        else {
            return
        }
        commitReasoningEffort(effort)
    }

    @objc private func networkSettingsCommitted(_ sender: Any?) {
        commitNetworkFields()
    }

    @objc private func retryStepperChanged(_ sender: NSStepper) {
        retryCountField.integerValue = sender.integerValue
        commitNetworkFields()
    }

    @objc private func timeoutStepperChanged(_ sender: NSStepper) {
        requestTimeoutField.integerValue = sender.integerValue
        commitNetworkFields()
    }

    @objc private func modelEnabledChanged(_ sender: AIProviderModelActionButton) {
        guard let selection = sender.modelSelection,
              selection.providerID == selectedProviderID
        else {
            return
        }
        setModelEnabled(selection.modelID, enabled: sender.state == .on)
    }

    @objc private func defaultModelPressed(_ sender: AIProviderModelActionButton) {
        guard let selection = sender.modelSelection,
              selection.providerID == selectedProviderID
        else {
            return
        }
        setDefaultModel(selection.modelID)
    }

    @objc private func addManualModelPressed(_ sender: Any?) {
        addManualModel(manualModelField.stringValue)
    }

    @objc private func refreshModelsPressed(_ sender: NSButton) {
        endPendingTextEditing()
        refreshSelectedProviderModels()
    }

    @objc private func visitWebsitePressed(_ sender: NSButton) {
        openProviderWebsite()
    }

    @objc private func testConnectionPressed(_ sender: NSButton) {
        endPendingTextEditing()
        testSelectedProviderConnection()
    }

    private func endPendingTextEditing() {
        _ = view.window?.makeFirstResponder(nil)
    }

    private func openProviderWebsite() {
        guard selectedProviderID == BuiltInAIProvider.mozheAPIID,
              let url = URL(string: BuiltInAIProvider.mozheAPIWebsiteURL)
        else {
            return
        }
        urlOpener.open(url)
    }

    private func commitDisplayName(_ rawDisplayName: String) {
        guard selectedProviderID != BuiltInAIProvider.mozheAPIID else {
            renderSelectedProvider()
            return
        }
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }
        let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName.isEmpty ? draft.provider.profile.displayName : displayName
        guard persistedProvider(id: selectedProviderID)?.displayName != normalizedName else {
            renderSelectedProvider()
            return
        }
        draft.provider.displayName = normalizedName
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
    }

    private func commitBaseURL(_ rawBaseURL: String) {
        guard selectedProviderID != BuiltInAIProvider.mozheAPIID else {
            renderSelectedProvider()
            return
        }
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }
        let baseURL = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard persistedProvider(id: selectedProviderID)?.baseURL != baseURL else {
            renderSelectedProvider()
            return
        }
        draft.provider.baseURL = baseURL
        clearVerificationAndCatalogTimestamps(in: &draft.provider)
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .catalogAndConnection)
    }

    private func commitAPIKey(_ rawAPIKey: String) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false, apiKey != Self.maskedAPIKeyPlaceholder else {
            renderSelectedProvider()
            return
        }
        do {
            if try mutationCoordinator.readAPIKey(for: selectedProviderID) == apiKey {
                renderSelectedProvider()
                return
            }
        } catch {
            // The transaction below remains the authoritative write path.
        }
        clearVerificationAndCatalogTimestamps(in: &draft.provider)
        draft.hasStoredAPIKey = true
        save(draft: draft, apiKeyUpdate: .replace(apiKey), impact: .catalogAndConnection)
    }

    private func pendingAPIKeyInput() -> String? {
        let value = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false, value != Self.maskedAPIKeyPlaceholder else {
            return nil
        }
        return value
    }

    @discardableResult
    private func persistPendingAPIKeyIfNeeded() -> Bool {
        guard let apiKey = pendingAPIKeyInput() else {
            return true
        }
        commitAPIKey(apiKey)
        return configurationMutationErrorMessage == nil
            && (editDrafts[selectedProviderID]?.hasStoredAPIKey ?? false)
    }

    private func toggleAPIKeyVisibility() {
        if isAPIKeyRevealed {
            concealAPIKey()
            return
        }

        guard persistPendingAPIKeyIfNeeded() else {
            return
        }
        let apiKey: String?
        do {
            apiKey = try mutationCoordinator.readAPIKey(for: selectedProviderID)
        } catch {
            configurationMutationErrorMessage = actionableMessage(for: error, apiKey: nil)
            renderSelectedProvider()
            return
        }
        guard let apiKey, apiKey.isEmpty == false else {
            updateAPIKeyActionAvailability(editable: providerForDisplay(id: selectedProviderID) != nil)
            return
        }

        revealedAPIKeyField.stringValue = apiKey
        apiKeyField.isHidden = true
        revealedAPIKeyField.isHidden = false
        isAPIKeyRevealed = true
        updateAPIKeyVisibilityButtonAppearance()
    }

    private func concealAPIKey() {
        isAPIKeyRevealed = false
        revealedAPIKeyField.stringValue = ""
        revealedAPIKeyField.isHidden = true
        apiKeyField.isHidden = false
        updateAPIKeyVisibilityButtonAppearance()
    }

    private func updateAPIKeyVisibilityButtonAppearance() {
        let symbolName = isAPIKeyRevealed ? "eye.slash" : "eye"
        let label = isAPIKeyRevealed ? "隐藏 API Key" : "显示 API Key"
        toggleAPIKeyVisibilityButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )
        toggleAPIKeyVisibilityButton.toolTip = label
        toggleAPIKeyVisibilityButton.setAccessibilityLabel(label)
    }

    private func updateAPIKeyActionAvailability(editable: Bool) {
        let hasStoredAPIKey = editDrafts[selectedProviderID]?.hasStoredAPIKey ?? false
        let hasPendingAPIKey = pendingAPIKeyInput() != nil
        toggleAPIKeyVisibilityButton.isEnabled = editable
            && (hasStoredAPIKey || hasPendingAPIKey || isAPIKeyRevealed)
        removeAPIKeyButton.isEnabled = editable && hasStoredAPIKey
    }

    private func removeAPIKey() {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }
        clearVerificationAndCatalogTimestamps(in: &draft.provider)
        draft.hasStoredAPIKey = false
        save(draft: draft, apiKeyUpdate: .remove, impact: .catalogAndConnection)
    }

    private func commitNetworkFields() {
        commitNetworkSettings(
            maxRetryCount: retryCountField.integerValue,
            requestTimeoutSeconds: requestTimeoutField.integerValue,
            userAgent: userAgentField.stringValue
        )
    }

    private func commitNetworkSettings(
        maxRetryCount: Int,
        requestTimeoutSeconds: Int,
        userAgent: String
    ) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }
        let retry = AppSettings.clampedAIRetryCount(maxRetryCount)
        let timeout = AppSettings.clampedAITimeoutSeconds(requestTimeoutSeconds)
        let normalizedUserAgent = AppSettings.normalizedAIUserAgent(userAgent)
        guard let persisted = persistedProvider(id: selectedProviderID),
              persisted.maxRetryCount != retry
                || persisted.requestTimeoutSeconds != timeout
                || persisted.userAgent != normalizedUserAgent
        else {
            renderSelectedProvider()
            return
        }
        draft.provider.maxRetryCount = retry
        draft.provider.requestTimeoutSeconds = timeout
        draft.provider.userAgent = normalizedUserAgent
        clearVerificationAndCatalogTimestamps(in: &draft.provider)
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .catalogAndConnection)
    }

    private func commitCompatibilityProtocol(_ preference: AICompatibilityProtocolPreference) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID),
              draft.provider.compatibilityProtocol != preference
        else {
            return
        }
        draft.provider.compatibilityProtocol = preference
        draft.provider.lastVerifiedAt = nil
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .connection)
    }

    private func commitManualContextBudget(_ rawValue: String) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              let modelID = selectedModelID,
              var draft = draft(for: selectedProviderID),
              let index = draft.provider.models.firstIndex(where: { $0.id == modelID }),
              draft.provider.models[index].capabilities.contextWindowTokens == nil
        else {
            renderSelectedProvider()
            return
        }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestedBudget = Int(trimmedValue), requestedBudget > 0 else {
            renderSelectedProvider()
            return
        }
        let budget = AIModelCapabilityConfiguration.clampedContextCharacterLimit(requestedBudget)
        var capabilities = draft.provider.models[index].capabilities
        guard capabilities.contextCharacterLimit != budget
                || capabilities.contextCharacterLimitSource != .manual
        else {
            renderSelectedProvider()
            return
        }
        capabilities.contextCharacterLimit = budget
        capabilities.contextCharacterLimitSource = .manual
        draft.provider.models[index].capabilities = capabilities.normalized()
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
    }

    private func commitManualReasoningEfforts() {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              let modelID = selectedModelID,
              var draft = draft(for: selectedProviderID),
              let index = draft.provider.models.firstIndex(where: { $0.id == modelID }),
              draft.provider.models[index].capabilities.supportedReasoningEffortsSource != .catalog
        else {
            renderSelectedProvider()
            return
        }
        let selectedEfforts = AIReasoningEffortPreference.allCases.enumerated().compactMap {
            manualReasoningEffortsControl.isSelected(forSegment: $0.offset) ? $0.element : nil
        }
        var capabilities = draft.provider.models[index].capabilities
        if selectedEfforts.isEmpty {
            capabilities.supportedReasoningEfforts = nil
            capabilities.supportedReasoningEffortsSource = .unknown
            capabilities.reasoningEffort = nil
            capabilities.reasoningEffortSource = .unknown
        } else {
            capabilities.supportedReasoningEfforts = selectedEfforts
            capabilities.supportedReasoningEffortsSource = .manual
            if let reasoningEffort = capabilities.reasoningEffort,
               selectedEfforts.contains(reasoningEffort) {
                capabilities.reasoningEffortSource = .manual
            } else {
                capabilities.reasoningEffort = selectedEfforts.first
                capabilities.reasoningEffortSource = .manual
            }
        }
        guard capabilities != draft.provider.models[index].capabilities else {
            renderSelectedProvider()
            return
        }
        draft.provider.models[index].capabilities = capabilities.normalized()
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
    }

    private func commitReasoningEffort(_ effort: AIReasoningEffortPreference) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              let modelID = selectedModelID,
              var draft = draft(for: selectedProviderID),
              let index = draft.provider.models.firstIndex(where: { $0.id == modelID })
        else {
            return
        }
        let capabilities = draft.provider.models[index].capabilities
        let availableEfforts: [AIReasoningEffortPreference]
        if capabilities.supportedReasoningEffortsSource == .catalog {
            availableEfforts = capabilities.supportedReasoningEfforts ?? []
        } else if capabilities.supportedReasoningEffortsSource == .manual {
            availableEfforts = capabilities.supportedReasoningEfforts ?? []
        } else {
            availableEfforts = []
        }
        guard availableEfforts.contains(effort),
              capabilities.reasoningEffort != effort || capabilities.reasoningEffortSource != .manual
        else {
            renderSelectedProvider()
            return
        }
        var updatedCapabilities = capabilities
        updatedCapabilities.reasoningEffort = effort
        updatedCapabilities.reasoningEffortSource = .manual
        draft.provider.models[index].capabilities = updatedCapabilities.normalized()
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
    }

    private func setModelEnabled(_ modelID: String, enabled: Bool) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID),
              let index = draft.provider.models.firstIndex(where: { $0.id == modelID })
        else {
            return
        }
        draft.provider.models[index].isEnabled = enabled
        if enabled {
            draft.provider.isEnabled = true
        }
        if enabled == false, draft.provider.defaultModelID == modelID {
            draft.provider.defaultModelID = draft.provider.models.first(where: { $0.isEnabled })?.id
        }
        draft.provider.lastVerifiedAt = nil
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .connection)
    }

    private func setDefaultModel(_ modelID: String) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID),
              let index = draft.provider.models.firstIndex(where: { $0.id == modelID })
        else {
            return
        }
        draft.provider.models[index].isEnabled = true
        draft.provider.defaultModelID = modelID
        draft.provider.isEnabled = true
        draft.provider.lastVerifiedAt = nil
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .connection)
    }

    private func addManualModel(_ rawModelID: String) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }
        let modelID = AppSettings.normalizedAIModelName(rawModelID)
        guard modelID.isEmpty == false else { return }
        if let index = draft.provider.models.firstIndex(where: { $0.id == modelID }) {
            draft.provider.models[index].isEnabled = true
        } else {
            draft.provider.models.append(
                AIProviderModelConfiguration(
                    id: modelID,
                    isEnabled: true,
                    isManual: true,
                    wasReturnedByLatestCatalog: false
                )
            )
        }
        draft.provider.isEnabled = true
        if draft.provider.defaultModelID == nil {
            draft.provider.defaultModelID = modelID
        }
        manualModelField.stringValue = ""
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
    }

    private func setSelectedProviderAsDefault() {
        let id = selectedProviderID
        guard providerExists(id) else { return }
        configurationMutationErrorMessage = nil
        do {
            currentEnvelope = try mutationCoordinator.setDefaultProvider(id: id)
            providerTableView.reloadData()
            syncProviderTableSelection()
            renderSelectedProvider()
        } catch {
            configurationMutationErrorMessage = actionableMessage(for: error, apiKey: nil)
            renderSelectedProvider()
        }
    }

    private func performDeleteSelectedProvider() {
        performDeleteProvider(id: selectedProviderID)
    }

    private func performDeleteProvider(id deletedID: UUID) {
        guard deletedID != BuiltInAIProvider.mozheAPIID,
              deletedID != BuiltInAIProvider.stacioRulesID
        else {
            return
        }
        let deletedProviderWasSelected = selectedProviderID == deletedID
        configurationMutationErrorMessage = nil
        invalidateRequests(for: deletedID, catalog: true, connection: true)
        do {
            let envelope = try mutationCoordinator.deleteProvider(id: deletedID)
            currentEnvelope = envelope
            editDrafts[deletedID] = nil
            catalogStates[deletedID] = nil
            connectionStates[deletedID] = nil
            if deletedProviderWasSelected || providerExists(selectedProviderID) == false {
                selectedProviderID = providerExists(envelope.defaultAIProviderID)
                    ? envelope.defaultAIProviderID
                    : preferredProviderID()
            }
            providerTableView.reloadData()
            syncProviderTableSelection()
            renderSelectedProvider()
        } catch {
            configurationMutationErrorMessage = actionableMessage(for: error, apiKey: nil)
            renderSelectedProvider()
        }
    }

    private func save(
        draft: AIProviderEditDraft,
        apiKeyUpdate: AIProviderAPIKeyUpdate,
        impact: AIProviderMutationImpact
    ) {
        let providerID = draft.provider.id
        let previousDraft = editDrafts[providerID]
        let replacementAPIKey: String?
        if case let .replace(apiKey) = apiKeyUpdate {
            replacementAPIKey = apiKey
        } else {
            replacementAPIKey = nil
        }
        configurationMutationErrorMessage = nil
        switch impact {
        case .none:
            break
        case .connection:
            invalidateRequests(for: providerID, catalog: false, connection: true)
        case .catalogAndConnection:
            invalidateRequests(for: providerID, catalog: true, connection: true)
            catalogStates[providerID] = .idle
        }
        do {
            let envelope = try mutationCoordinator.saveProvider(
                draft.provider,
                apiKeyUpdate: apiKeyUpdate
            )
            currentEnvelope = envelope
            if let savedProvider = envelope.aiProviders.first(where: { $0.id == providerID }) {
                editDrafts[providerID] = AIProviderEditDraft(
                    provider: savedProvider,
                    hasStoredAPIKey: draft.hasStoredAPIKey
                )
            }
            providerTableView.reloadData()
            syncProviderTableSelection()
            renderSelectedProvider()
        } catch {
            if let persistedProvider = persistedProvider(id: providerID) {
                let hasStoredAPIKey: Bool
                do {
                    hasStoredAPIKey = try mutationCoordinator.readAPIKey(for: providerID) != nil
                } catch {
                    hasStoredAPIKey = previousDraft?.hasStoredAPIKey ?? false
                }
                editDrafts[providerID] = AIProviderEditDraft(
                    provider: persistedProvider,
                    hasStoredAPIKey: hasStoredAPIKey
                )
            } else {
                editDrafts[providerID] = nil
            }
            configurationMutationErrorMessage = actionableMessage(
                for: error,
                apiKey: replacementAPIKey
            )
            renderSelectedProvider()
        }
    }

    private func refreshSelectedProviderModels() {
        guard persistPendingAPIKeyIfNeeded() else {
            return
        }
        let providerID = selectedProviderID
        guard providerID != BuiltInAIProvider.stacioRulesID,
              isCatalogLoading(providerID) == false,
              let draft = draft(for: providerID)
        else {
            return
        }

        let apiKey: String?
        do {
            apiKey = try mutationCoordinator.readAPIKey(for: providerID)
        } catch {
            catalogStates[providerID] = .failed(actionableMessage(for: error, apiKey: nil))
            renderSelectedProvider()
            return
        }

        let token = UUID()
        catalogRequestTokens[providerID] = token
        catalogStates[providerID] = .loading
        renderSelectedProvider()

        let providerSnapshot = draft.provider
        let loader = UncheckedAIProviderCatalogBox(modelCatalogLoader)
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result {
                try loader.value.listModelEntries(for: providerSnapshot, apiKey: apiKey)
            }
            mainExecutor {
                self?.finishCatalogRequest(
                    providerID: providerID,
                    token: token,
                    apiKey: apiKey,
                    result: result
                )
            }
        }
    }

    private func finishCatalogRequest(
        providerID: UUID,
        token: UUID,
        apiKey: String?,
        result: Result<[AIModelCatalogEntry], Error>
    ) {
        guard acceptsCatalogResult(providerID: providerID, token: token) else { return }
        switch result {
        case let .success(entries):
            guard var draft = draft(for: providerID) else { return }
            draft.provider.models = AIProviderModelCatalogMerger.merge(
                existing: draft.provider.models,
                fetchedEntries: entries
            )
            draft.provider.lastModelSyncAt = now()
            do {
                let envelope = try mutationCoordinator.saveProvider(
                    draft.provider,
                    apiKeyUpdate: .unchanged
                )
                currentEnvelope = envelope
                if let saved = envelope.aiProviders.first(where: { $0.id == providerID }) {
                    editDrafts[providerID] = AIProviderEditDraft(
                        provider: saved,
                        hasStoredAPIKey: draft.hasStoredAPIKey
                    )
                }
                catalogStates[providerID] = .loaded
                providerTableView.reloadData()
                if selectedProviderID == providerID {
                    renderSelectedProvider()
                }
            } catch {
                catalogStates[providerID] = .failed(actionableMessage(for: error, apiKey: apiKey))
                if selectedProviderID == providerID {
                    renderSelectedProvider()
                }
            }
        case let .failure(error):
            catalogStates[providerID] = .failed(actionableMessage(for: error, apiKey: apiKey))
            if selectedProviderID == providerID {
                renderSelectedProvider()
            }
        }
    }

    private func acceptsCatalogResult(providerID: UUID, token: UUID) -> Bool {
        catalogRequestTokens[providerID] == token
            && currentEnvelope.aiProviders.contains(where: { $0.id == providerID })
    }

    private func testSelectedProviderConnection() {
        guard persistPendingAPIKeyIfNeeded() else {
            return
        }
        let providerID = selectedProviderID
        guard providerID != BuiltInAIProvider.stacioRulesID,
              isConnectionTesting(providerID) == false,
              let draft = draft(for: providerID),
              let defaultModelID = draft.provider.defaultModelID,
              defaultModelID.isEmpty == false
        else {
            return
        }

        let apiKey: String?
        do {
            apiKey = try mutationCoordinator.readAPIKey(for: providerID)
        } catch {
            connectionStates[providerID] = .failed(actionableMessage(for: error, apiKey: nil))
            renderSelectedProvider()
            return
        }

        let token = UUID()
        connectionRequestTokens[providerID] = token
        connectionStates[providerID] = .testing
        renderSelectedProvider()

        let providerSnapshot = draft.provider
        let tester = UncheckedAIProviderConnectionTesterBox(connectionTester)
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result {
                try tester.value.testConnection(
                    provider: providerSnapshot,
                    modelID: defaultModelID,
                    apiKey: apiKey
                )
            }
            mainExecutor {
                self?.finishConnectionTest(
                    providerID: providerID,
                    token: token,
                    apiKey: apiKey,
                    result: result
                )
            }
        }
    }

    private func finishConnectionTest(
        providerID: UUID,
        token: UUID,
        apiKey: String?,
        result: Result<AIAssistantConnectionTestResult, Error>
    ) {
        guard connectionRequestTokens[providerID] == token,
              currentEnvelope.aiProviders.contains(where: { $0.id == providerID })
        else {
            return
        }
        switch result {
        case let .success(testResult):
            guard var draft = draft(for: providerID) else { return }
            draft.provider.lastVerifiedAt = now()
            do {
                let envelope = try mutationCoordinator.saveProvider(
                    draft.provider,
                    apiKeyUpdate: .unchanged
                )
                currentEnvelope = envelope
                if let saved = envelope.aiProviders.first(where: { $0.id == providerID }) {
                    editDrafts[providerID] = AIProviderEditDraft(
                        provider: saved,
                        hasStoredAPIKey: draft.hasStoredAPIKey
                    )
                }
                connectionStates[providerID] = .succeeded(
                    redactedMessage(testResult.message, apiKey: apiKey)
                )
                providerTableView.reloadData()
            } catch {
                connectionStates[providerID] = .failed(actionableMessage(for: error, apiKey: apiKey))
            }
        case let .failure(error):
            connectionStates[providerID] = .failed(actionableMessage(for: error, apiKey: apiKey))
        }
        if selectedProviderID == providerID {
            renderSelectedProvider()
        }
    }

    private func renderSelectedProvider() {
        let provider = providerForDisplay(id: selectedProviderID)
        let isMozheAPI = selectedProviderID == BuiltInAIProvider.mozheAPIID && provider != nil
        reconcileSelectedModel()
        concealAPIKey()

        providerNameLabel.stringValue = provider.map(displayName(for:)) ?? "供应商不可用"
        updateProviderStatus(provider: provider)

        displayNameField.stringValue = provider.map(displayName(for:)) ?? ""
        baseURLField.stringValue = provider.map(displayedBaseURL(for:)) ?? ""
        if let draft = editDrafts[selectedProviderID], draft.hasStoredAPIKey {
            apiKeyField.stringValue = Self.maskedAPIKeyPlaceholder
        } else {
            apiKeyField.stringValue = ""
        }

        let editable = provider != nil
        let identityEditable = editable && isMozheAPI == false
        displayNameField.isEditable = identityEditable
        displayNameField.isSelectable = identityEditable
        displayNameField.isEnabled = editable
        baseURLField.isEditable = identityEditable
        baseURLField.isSelectable = editable
        baseURLField.isEnabled = editable
        [apiKeyField, userAgentField, retryCountField, requestTimeoutField].forEach {
            $0.isEditable = editable
            $0.isSelectable = editable
            $0.isEnabled = editable
        }
        compatibilityProtocolPopup.isEnabled = editable
        retryCountStepper.isEnabled = editable
        requestTimeoutStepper.isEnabled = editable
        updateAPIKeyActionAvailability(editable: editable)
        removeProviderButton.isEnabled = editable && isMozheAPI == false
        visitWebsiteButton.isHidden = isMozheAPI == false
        updateAsyncActionAvailability(provider: provider, editable: editable)
        modelSearchField.isEnabled = editable
        manualModelField.isEnabled = editable
        addManualModelButton.isEnabled = editable

        if let provider {
            compatibilityProtocolPopup.selectItem(at: provider.compatibilityProtocol == .responses ? 1 : 0)
            retryCountField.integerValue = provider.maxRetryCount
            retryCountStepper.integerValue = provider.maxRetryCount
            requestTimeoutField.integerValue = provider.requestTimeoutSeconds
            requestTimeoutStepper.integerValue = provider.requestTimeoutSeconds
            userAgentField.stringValue = provider.userAgent
        } else {
            compatibilityProtocolPopup.selectItem(at: 0)
            retryCountField.stringValue = ""
            requestTimeoutField.stringValue = ""
            userAgentField.stringValue = ""
        }

        updateCatalogStatus(providerID: selectedProviderID)
        modelTableView.reloadData()
        syncModelTableSelection()
        renderSelectedModelCapabilities(provider: provider, editable: editable)
    }

    private func renderSelectedModelCapabilities(
        provider: AIProviderConfiguration?,
        editable: Bool
    ) {
        guard let modelID = selectedModelID,
              let model = provider?.models.first(where: { $0.id == modelID })
        else {
            modelCapabilityStack.isHidden = true
            return
        }

        modelCapabilityStack.isHidden = false
        selectedModelCapabilityLabel.stringValue = model.id

        let capabilities = model.capabilities
        let hasCatalogContextWindow = capabilities.contextWindowTokens != nil
        catalogContextWindowRow?.isHidden = hasCatalogContextWindow == false
        manualContextBudgetRow?.isHidden = hasCatalogContextWindow
        if let contextWindowTokens = capabilities.contextWindowTokens {
            let budgetSource = capabilities.contextCharacterLimitSource == .manual
                ? "手动"
                : "自动"
            catalogContextWindowLabel.stringValue = "\(formattedNumber(contextWindowTokens)) tokens（目录同步） · 请求预算 \(formattedNumber(capabilities.effectiveContextCharacterLimit)) 字符（\(budgetSource)）"
        }
        manualContextBudgetField.stringValue = String(capabilities.effectiveContextCharacterLimit)
        manualContextBudgetField.isEditable = editable && hasCatalogContextWindow == false
        manualContextBudgetField.isSelectable = editable && hasCatalogContextWindow == false
        manualContextBudgetField.isEnabled = editable && hasCatalogContextWindow == false

        let hasCatalogReasoningMetadata = capabilities.supportedReasoningEffortsSource == .catalog
        let catalogEfforts = capabilities.supportedReasoningEfforts ?? []
        catalogReasoningEffortsRow?.isHidden = hasCatalogReasoningMetadata == false
        manualReasoningEffortsRow?.isHidden = hasCatalogReasoningMetadata
        if hasCatalogReasoningMetadata {
            catalogReasoningEffortsLabel.stringValue = catalogEfforts.isEmpty
                ? "目录同步 · 未提供可用档位"
                : "\(catalogEfforts.map { reasoningEffortTitle($0) }.joined(separator: "、"))（目录同步）"
        }

        let manualEfforts = capabilities.supportedReasoningEffortsSource == .manual
            ? capabilities.supportedReasoningEfforts ?? []
            : []
        for (index, effort) in AIReasoningEffortPreference.allCases.enumerated() {
            manualReasoningEffortsControl.setSelected(manualEfforts.contains(effort), forSegment: index)
            manualReasoningEffortsControl.setEnabled(editable && hasCatalogReasoningMetadata == false, forSegment: index)
        }
        manualReasoningEffortsControl.isEnabled = editable && hasCatalogReasoningMetadata == false

        let availableReasoningEfforts = hasCatalogReasoningMetadata
            ? catalogEfforts
            : manualEfforts
        configureReasoningEffortPopup(
            availableEfforts: availableReasoningEfforts,
            selectedEffort: capabilities.reasoningEffort,
            isEditable: editable
        )
    }

    private func revealSelectedModelCapabilities() {
        guard modelCapabilityStack.isHidden == false,
              let document = detailDocumentView
        else {
            return
        }
        view.layoutSubtreeIfNeeded()
        let capabilityRect = modelCapabilityStack.convert(modelCapabilityStack.bounds, to: document)
        document.scrollToVisible(capabilityRect.insetBy(dx: 0, dy: -8))
        if let detailScrollView {
            detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
        }
    }

    private func configureReasoningEffortPopup(
        availableEfforts: [AIReasoningEffortPreference],
        selectedEffort: AIReasoningEffortPreference?,
        isEditable: Bool
    ) {
        reasoningEffortPopup.removeAllItems()
        guard availableEfforts.isEmpty == false else {
            reasoningEffortPopup.addItem(withTitle: "未配置")
            reasoningEffortPopup.isEnabled = false
            return
        }

        for effort in availableEfforts {
            reasoningEffortPopup.addItem(withTitle: reasoningEffortTitle(effort))
            reasoningEffortPopup.item(at: reasoningEffortPopup.numberOfItems - 1)?.representedObject = effort.rawValue
        }
        let effectiveEffort = selectedEffort.flatMap { availableEfforts.contains($0) ? $0 : nil }
            ?? availableEfforts.first
        if let effectiveEffort,
           let item = reasoningEffortPopup.itemArray.first(where: {
               ($0.representedObject as? String) == effectiveEffort.rawValue
           }) {
            reasoningEffortPopup.select(item)
        }
        reasoningEffortPopup.isEnabled = isEditable
    }

    private func updateProviderStatus(
        provider: AIProviderConfiguration?
    ) {
        if let settingsLoadErrorMessage {
            providerStatusLabel.stringValue = settingsLoadErrorMessage
            providerStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
            return
        }
        if let configurationMutationErrorMessage {
            providerStatusLabel.stringValue = configurationMutationErrorMessage
            providerStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
            return
        }
        guard let provider else {
            providerStatusLabel.stringValue = "供应商不可用"
            providerStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
            return
        }
        switch connectionStates[provider.id] ?? .idle {
        case .idle:
            providerStatusLabel.stringValue = providerStatusText(provider)
            providerStatusLabel.textColor = providerStatusColor(provider)
        case .testing:
            providerStatusLabel.stringValue = "正在测试连接..."
            providerStatusLabel.textColor = StacioDesignSystem.theme.accentColor
        case let .succeeded(message):
            providerStatusLabel.stringValue = message
            providerStatusLabel.textColor = StacioDesignSystem.theme.successColor
        case let .failed(message):
            providerStatusLabel.stringValue = message
            providerStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
        }
    }

    private func updateCatalogStatus(providerID: UUID) {
        switch catalogStates[providerID] ?? .idle {
        case .idle:
            if let lastSync = providerForDisplay(id: providerID)?.lastModelSyncAt {
                catalogStatusLabel.stringValue = "已同步 · \(Self.shortDateFormatter.string(from: lastSync))"
            } else {
                catalogStatusLabel.stringValue = "尚未获取模型"
            }
            catalogStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        case .loading:
            catalogStatusLabel.stringValue = "正在获取模型..."
            catalogStatusLabel.textColor = StacioDesignSystem.theme.accentColor
        case .loaded:
            catalogStatusLabel.stringValue = "模型目录已更新"
            catalogStatusLabel.textColor = StacioDesignSystem.theme.successColor
        case let .failed(message):
            catalogStatusLabel.stringValue = message
            catalogStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
        }
    }

    private func syncProviderTableSelection() {
        isSynchronizingProviderSelection = true
        defer { isSynchronizingProviderSelection = false }
        if let row = visibleProviderIDs.firstIndex(of: selectedProviderID) {
            providerTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            providerTableView.scrollRowToVisible(row)
        } else {
            providerTableView.deselectAll(nil)
        }
    }

    private func syncModelTableSelection() {
        isSynchronizingModelSelection = true
        defer { isSynchronizingModelSelection = false }
        guard let selectedModelID,
              let row = visibleModels.firstIndex(where: { $0.id == selectedModelID })
        else {
            modelTableView.deselectAll(nil)
            return
        }
        modelTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        modelTableView.scrollRowToVisible(row)
    }

    private func reconcileSelectedModel() {
        guard let selectedModelID,
              visibleModels.contains(where: { $0.id == selectedModelID }) == false
        else {
            return
        }
        self.selectedModelID = nil
    }

    private func providerExists(_ id: UUID) -> Bool {
        id != BuiltInAIProvider.stacioRulesID
            && currentEnvelope.aiProviders.contains(where: { $0.id == id })
    }

    private func reconcileSelectionAfterReload(_ requestedProviderID: UUID?) {
        if let requestedProviderID, providerExists(requestedProviderID) {
            selectedProviderID = requestedProviderID
        } else if providerExists(selectedProviderID) == false {
            selectedProviderID = preferredProviderID()
        }
    }

    private func preferredProviderID() -> UUID {
        if providerExists(BuiltInAIProvider.mozheAPIID) {
            return BuiltInAIProvider.mozheAPIID
        }
        return currentEnvelope.aiProviders
            .first(where: { $0.id != BuiltInAIProvider.stacioRulesID })?
            .id ?? BuiltInAIProvider.mozheAPIID
    }

    private func providerForDisplay(id: UUID) -> AIProviderConfiguration? {
        editDrafts[id]?.provider
            ?? currentEnvelope.aiProviders.first(where: { $0.id == id })
    }

    private func persistedProvider(id: UUID) -> AIProviderConfiguration? {
        currentEnvelope.aiProviders.first(where: { $0.id == id })
    }

    @discardableResult
    private func draft(for id: UUID) -> AIProviderEditDraft? {
        if let draft = editDrafts[id] {
            return draft
        }
        guard let provider = currentEnvelope.aiProviders.first(where: { $0.id == id }) else {
            return nil
        }
        let hasStoredAPIKey: Bool
        do {
            hasStoredAPIKey = try mutationCoordinator.readAPIKey(for: id) != nil
        } catch {
            hasStoredAPIKey = false
            connectionStates[id] = .failed(actionableMessage(for: error, apiKey: nil))
        }
        let draft = AIProviderEditDraft(provider: provider, hasStoredAPIKey: hasStoredAPIKey)
        editDrafts[id] = draft
        return draft
    }

    private func providerSummary(for id: UUID) -> AIProviderSummary {
        guard let provider = providerForDisplay(id: id) else {
            return AIProviderSummary(
                id: id,
                displayName: "未知供应商",
                statusText: "不可用",
                enabledModelCount: 0,
                totalModelCount: 0,
                isDefault: false,
                isRecommended: false
            )
        }
        return AIProviderSummary(
            id: id,
            displayName: displayName(for: provider),
            statusText: providerStatusText(provider),
            enabledModelCount: provider.models.filter(\.isEnabled).count,
            totalModelCount: provider.models.count,
            isDefault: currentEnvelope.defaultAIProviderID == id,
            isRecommended: id == BuiltInAIProvider.mozheAPIID
        )
    }

    private func displayName(for provider: AIProviderConfiguration) -> String {
        provider.id == BuiltInAIProvider.mozheAPIID
            ? BuiltInAIProvider.mozheAPIDisplayName
            : provider.displayName
    }

    private func displayedBaseURL(for provider: AIProviderConfiguration) -> String {
        provider.id == BuiltInAIProvider.mozheAPIID
            ? BuiltInAIProvider.mozheAPIBaseURL
            : provider.baseURL
    }

    private func providerStatusText(_ provider: AIProviderConfiguration) -> String {
        if provider.isEnabled == false {
            return "已停用"
        }
        if provider.defaultModelID == nil {
            return "未选择默认模型"
        }
        if provider.lastVerifiedAt == nil {
            return "未验证"
        }
        return "已验证"
    }

    private func providerStatusColor(for id: UUID) -> NSColor {
        guard let provider = providerForDisplay(id: id) else {
            return StacioDesignSystem.theme.secondaryTextColor
        }
        return providerStatusColor(provider)
    }

    private func providerStatusColor(_ provider: AIProviderConfiguration) -> NSColor {
        if provider.isEnabled == false {
            return StacioDesignSystem.theme.secondaryTextColor
        }
        if provider.lastVerifiedAt == nil || provider.defaultModelID == nil {
            return StacioDesignSystem.theme.warningColor
        }
        return StacioDesignSystem.theme.successColor
    }

    private func modelStatusText(_ model: AIProviderModelConfiguration) -> String {
        if model.isManual {
            return "手动添加"
        }
        if model.wasReturnedByLatestCatalog {
            return "目录可用"
        }
        return "目录中已移除"
    }

    private func modelStatusColor(_ model: AIProviderModelConfiguration) -> NSColor {
        if model.isManual {
            return StacioDesignSystem.theme.accentColor
        }
        return model.wasReturnedByLatestCatalog
            ? StacioDesignSystem.theme.successColor
            : StacioDesignSystem.theme.warningColor
    }

    private func invalidateRequests(for providerID: UUID, catalog: Bool, connection: Bool) {
        if catalog {
            catalogRequestTokens[providerID] = nil
        }
        if connection {
            connectionRequestTokens[providerID] = nil
            connectionStates[providerID] = .idle
        }
    }

    private func invalidateRequestsForRequestSensitiveTyping(providerID: UUID) {
        invalidateRequests(for: providerID, catalog: true, connection: true)
        catalogStates[providerID] = .idle
        if selectedProviderID == providerID {
            let provider = providerForDisplay(id: providerID)
            updateAsyncActionAvailability(provider: provider, editable: provider != nil)
        }
    }

    private func updateAsyncActionAvailability(
        provider: AIProviderConfiguration?,
        editable: Bool
    ) {
        let providerID = provider?.id ?? selectedProviderID
        testConnectionButton.isEnabled = editable
            && provider?.defaultModelID != nil
            && isConnectionTesting(providerID) == false
        refreshModelsButton.isEnabled = editable
            && isCatalogLoading(providerID) == false
    }

    private func isCatalogLoading(_ providerID: UUID) -> Bool {
        if case .loading = catalogStates[providerID] {
            return true
        }
        return false
    }

    private func isConnectionTesting(_ providerID: UUID) -> Bool {
        if case .testing = connectionStates[providerID] {
            return true
        }
        return false
    }

    private func clearVerificationAndCatalogTimestamps(in provider: inout AIProviderConfiguration) {
        provider.lastVerifiedAt = nil
        provider.lastModelSyncAt = nil
    }

    private func actionableMessage(for error: Error, apiKey: String?) -> String {
        var message = replacingExplicitAPIKey(
            in: RuntimeDiagnosticFormatter.userMessage(for: error),
            apiKey: apiKey
        )
        if message.isEmpty {
            message = "操作失败"
        }
        if message.contains("请检查") == false {
            message += "。请检查 Base URL、API Key 和网络后重试。"
        }
        return message
    }

    private func redactedMessage(_ rawMessage: String, apiKey: String?) -> String {
        replacingExplicitAPIKey(
            in: RuntimeDiagnosticFormatter.userMessage(rawMessage),
            apiKey: apiKey
        )
    }

    private func replacingExplicitAPIKey(in rawMessage: String, apiKey: String?) -> String {
        var message = rawMessage
        if let apiKey {
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedKey.isEmpty == false {
                message = message.replacingOccurrences(
                    of: normalizedKey,
                    with: L10n.Diagnostics.redactedCredential
                )
            }
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func reasoningEffortTitle(_ effort: AIReasoningEffortPreference) -> String {
        switch effort {
        case .minimal:
            return "最低"
        case .low:
            return "低"
        case .medium:
            return "中"
        case .high:
            return "高"
        }
    }

    private func formattedNumber(_ value: Int) -> String {
        Self.decimalNumberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private static let decimalNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter
    }()
}
