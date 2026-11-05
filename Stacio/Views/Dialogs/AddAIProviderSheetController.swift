import AppKit
import Foundation

struct AddAIProviderDraft {
    var descriptor: NativeRuntimeCatalogEntry?
    var displayName: String
    var baseURL: String
    var apiKey: String
    var models: [AIProviderModelConfiguration]
    var defaultModelID: String?
    var lastModelSyncAt: Date?
    var confirmedCredentialOrigin: String?

    func makeConfiguration(id: UUID) -> AIProviderConfiguration? {
        guard let descriptor,
              var configuration = AIProviderConfiguration.catalogDraft(
                  descriptor: descriptor,
                  id: id
              )
        else {
            return nil
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.displayName = trimmedName
        configuration.baseURL = trimmedBaseURL
        configuration.models = models
        configuration.defaultModelID = defaultModelID
        configuration.isEnabled = false
        configuration.lastModelSyncAt = lastModelSyncAt
        configuration.confirmedCredentialOrigin = confirmedCredentialOrigin

        let suggestedURL = descriptor.suggestedBaseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if suggestedURL == trimmedBaseURL {
            configuration.baseURLSource = .catalogSuggestion
            configuration.wasBaseURLUserEdited = false
        } else {
            configuration.baseURLSource = .userProvided
            configuration.wasBaseURLUserEdited = true
        }

        return AIProviderSettingsNormalizer.normalized(
            AIProviderSettingsEnvelope(
                aiProviders: [configuration],
                defaultAIProviderID: BuiltInAIProvider.stacioRulesID
            )
        ).aiProviders.first
    }
}

@MainActor
final class AddAIProviderSheetController: NSViewController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSTextFieldDelegate,
    NSSearchFieldDelegate
{
    private struct FetchInputSnapshot: Equatable {
        let catalogID: String?
        let baseURL: String
        let apiKey: String
    }

    private struct FetchRequest: Equatable {
        let token: UUID
        let owner: UUID
        let input: FetchInputSnapshot
    }

    var onSaved: ((UUID) -> Void)?
    var onCancel: (() -> Void)?

    private let providerIDGenerator: () -> UUID
    private let mutationCoordinator: AIProviderMutationCoordinating
    private let modelCatalogLoader: AIModelCatalogLoading
    private let runtimeCatalog: BundledRuntimeCatalog
    private let websiteOpener: (URL) -> Bool
    private let credentialOriginConfirmationHandler: AIProviderCredentialOriginConfirmationHandler
    private let backgroundExecutor: AIProviderTaskExecutor
    private let mainExecutor: AIProviderTaskExecutor
    private let catalogEntries: [NativeRuntimeCatalogEntry]

    private var providerID: UUID?
    private var activeFetchRequest: FetchRequest?
    private var stagingOwner: UUID?
    private var completedFetchInput: FetchInputSnapshot?
    private var persistedCredentialInput: FetchInputSnapshot?
    private var hasPersistedDraft = false
    private var hasPersistedCredential = false
    private var isFetching = false
    private var isSaving = false
    private var saveRequestToken: UUID?
    private var didFinish = false
    private var didClose = false
    private var modelSearchQuery = ""
    private let persistenceGate = AddAIProviderPersistenceGate()
    private let stagingRegistry = AddAIProviderStagingRegistry()
    private var draft = AddAIProviderDraft(
        descriptor: nil,
        displayName: "",
        baseURL: "",
        apiKey: "",
        models: [],
        defaultModelID: nil,
        lastModelSyncAt: nil,
        confirmedCredentialOrigin: nil
    )

    private let profilePopup = NSPopUpButton()
    private let displayNameField = NSTextField()
    private let baseURLField = NSTextField()
    private let apiKeyLabel = NSTextField(labelWithString: L10n.Settings.apiKey)
    private let apiKeyField = NSSecureTextField()
    private let websiteButton = NSButton()
    private let websiteHostLabel = NSTextField(labelWithString: "")
    private var websiteGridRow: NSGridRow?
    private var apiKeyGridRow: NSGridRow?
    private let fetchModelsButton = NSButton()
    private let modelSearchField = NSSearchField()
    private let modelTableView = NSTableView()
    private let modelEmptyStateLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let manualModelField = NSTextField()
    private let addManualModelButton = NSButton()
    private let manualModelRow = NSStackView()
    private let cancelButton = NSButton()
    private let saveButton = NSButton()

    init(
        providerIDGenerator: @escaping () -> UUID = UUID.init,
        mutationCoordinator: AIProviderMutationCoordinating,
        modelCatalogLoader: AIModelCatalogLoading,
        runtimeCatalog: BundledRuntimeCatalog = .shared,
        websiteOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        credentialOriginConfirmationHandler: @escaping AIProviderCredentialOriginConfirmationHandler = {
            AIProviderCredentialOriginConfirmationPresenter.confirm($0)
        },
        backgroundExecutor: @escaping AIProviderTaskExecutor = { operation in
            let box = UncheckedAddAIProviderTask(operation)
            DispatchQueue.global(qos: .userInitiated).async {
                box.operation()
            }
        },
        mainExecutor: @escaping AIProviderTaskExecutor = { operation in
            if Thread.isMainThread {
                operation()
            } else {
                let box = UncheckedAddAIProviderTask(operation)
                DispatchQueue.main.async {
                    box.operation()
                }
            }
        }
    ) {
        self.providerIDGenerator = providerIDGenerator
        self.mutationCoordinator = mutationCoordinator
        self.modelCatalogLoader = modelCatalogLoader
        self.runtimeCatalog = runtimeCatalog
        self.websiteOpener = websiteOpener
        self.credentialOriginConfirmationHandler = credentialOriginConfirmationHandler
        self.backgroundExecutor = backgroundExecutor
        self.mainExecutor = mainExecutor
        catalogEntries = runtimeCatalog.nativeRuntimeEntriesForCreation()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 600, height: 540))
        StacioDesignSystem.applyRootSurface(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.sheet")

        configureControls()

        let title = NSTextField(labelWithString: L10n.Settings.addAIProviderTitle)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor

        let description = NSTextField(wrappingLabelWithString: L10n.Settings.addAIProviderDescription)
        description.textColor = StacioDesignSystem.theme.secondaryTextColor
        description.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let header = NSStackView(views: [title, description])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        let websiteRow = NSStackView(views: [websiteButton, websiteHostLabel])
        websiteRow.orientation = .horizontal
        websiteRow.alignment = .centerY
        websiteRow.spacing = 8

        let form = NSGridView(views: [
            [makeLabel(L10n.Settings.addAIProviderTemplate), profilePopup],
            [makeLabel(L10n.Settings.addAIProviderDisplayName), displayNameField],
            [makeLabel(L10n.Settings.baseURL), baseURLField],
            [makeLabel(L10n.Settings.addAIProviderOfficialEntry), websiteRow],
            [apiKeyLabel, apiKeyField]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false
        form.setContentHuggingPriority(.required, for: .vertical)
        form.setContentCompressionResistancePriority(.required, for: .vertical)
        websiteGridRow = form.row(at: 3)
        apiKeyGridRow = form.row(at: 4)

        let modelScrollView = NSScrollView()
        modelScrollView.translatesAutoresizingMaskIntoConstraints = false
        modelScrollView.drawsBackground = false
        modelScrollView.borderType = .bezelBorder
        modelScrollView.hasVerticalScroller = true
        modelScrollView.autohidesScrollers = true
        modelScrollView.documentView = modelTableView
        modelScrollView.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.models")
        modelScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        modelEmptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        modelEmptyStateLabel.alignment = .center
        modelEmptyStateLabel.maximumNumberOfLines = 3
        modelEmptyStateLabel.lineBreakMode = .byWordWrapping
        modelEmptyStateLabel.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.modelEmptyState")
        let modelClipView = modelScrollView.contentView
        modelClipView.addSubview(
            modelEmptyStateLabel,
            positioned: .above,
            relativeTo: modelTableView
        )
        NSLayoutConstraint.activate([
            modelEmptyStateLabel.centerXAnchor.constraint(equalTo: modelClipView.centerXAnchor),
            modelEmptyStateLabel.centerYAnchor.constraint(equalTo: modelClipView.centerYAnchor),
            modelEmptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: modelClipView.leadingAnchor, constant: 24),
            modelEmptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: modelClipView.trailingAnchor, constant: -24)
        ])

        manualModelRow.setViews([manualModelField, addManualModelButton], in: .leading)
        manualModelRow.orientation = .horizontal
        manualModelRow.alignment = .centerY
        manualModelRow.spacing = 8

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        saveButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        footer.addSubview(cancelButton)
        footer.addSubview(saveButton)

        let stack = NSStackView(views: [
            header,
            form,
            fetchModelsButton,
            modelSearchField,
            modelScrollView,
            manualModelRow,
            statusLabel,
            footer
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(9, after: header)
        stack.setCustomSpacing(9, after: statusLabel)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),

            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            profilePopup.widthAnchor.constraint(equalToConstant: 360),
            displayNameField.widthAnchor.constraint(equalToConstant: 360),
            baseURLField.widthAnchor.constraint(equalToConstant: 360),
            websiteRow.widthAnchor.constraint(equalToConstant: 360),
            apiKeyField.widthAnchor.constraint(equalToConstant: 360),
            fetchModelsButton.heightAnchor.constraint(equalToConstant: 30),
            modelSearchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelSearchField.heightAnchor.constraint(equalToConstant: 28),
            modelScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            manualModelField.widthAnchor.constraint(equalToConstant: 360),
            addManualModelButton.heightAnchor.constraint(equalToConstant: 30),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            saveButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            saveButton.heightAnchor.constraint(equalToConstant: 30),
            cancelButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        root.onEffectiveAppearanceRefresh = { [weak self] in
            self?.reloadModelList()
        }
        view = root
        render()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        invalidateAndClose()
    }

    private func configureControls() {
        profilePopup.removeAllItems()
        profilePopup.addItem(withTitle: L10n.Settings.addAIProviderChooseProvider)
        profilePopup.item(at: 0)?.tag = 0
        for (index, descriptor) in catalogEntries.enumerated() {
            let title = descriptor.isCodingPlan
                ? "\(descriptor.displayName) · Coding Plan"
                : descriptor.displayName
            profilePopup.addItem(withTitle: title)
            profilePopup.item(at: index + 1)?.tag = index + 1
        }
        profilePopup.selectItem(at: 0)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profilePopup.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.profile")
        StacioDesignSystem.stylePopupButton(profilePopup)

        configureTextField(
            displayNameField,
            identifier: "Stacio.Settings.addAIProvider.displayName",
            placeholder: L10n.Settings.addAIProviderDisplayName
        )
        configureTextField(
            baseURLField,
            identifier: "Stacio.Settings.addAIProvider.baseURL",
            placeholder: "https://api.example.com/v1"
        )
        configureTextField(
            apiKeyField,
            identifier: "Stacio.Settings.addAIProvider.apiKey",
            placeholder: "sk-..."
        )
        apiKeyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        apiKeyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        websiteButton.image = NSImage(
            systemSymbolName: "arrow.up.right.square",
            accessibilityDescription: L10n.Settings.addAIProviderOfficialEntry
        )
        websiteButton.imagePosition = .imageLeading
        websiteButton.target = self
        websiteButton.action = #selector(openWebsitePressed(_:))
        websiteButton.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.website")
        StacioDesignSystem.styleSheetButton(websiteButton)

        websiteHostLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        websiteHostLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        websiteHostLabel.lineBreakMode = .byTruncatingMiddle
        websiteHostLabel.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.websiteHost")

        fetchModelsButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        fetchModelsButton.imagePosition = .imageLeading
        fetchModelsButton.target = self
        fetchModelsButton.action = #selector(fetchModelsPressed(_:))
        fetchModelsButton.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.fetchModels")
        StacioDesignSystem.styleSheetButton(fetchModelsButton)

        modelSearchField.placeholderString = L10n.Settings.addAIProviderModelSearch
        modelSearchField.delegate = self
        modelSearchField.target = self
        modelSearchField.action = #selector(modelSearchChanged(_:))
        modelSearchField.translatesAutoresizingMaskIntoConstraints = false
        modelSearchField.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.modelSearch")
        StacioDesignSystem.styleTextField(modelSearchField)

        configureModelTable()

        configureTextField(
            manualModelField,
            identifier: "Stacio.Settings.addAIProvider.manualModel",
            placeholder: "gpt-4.1-mini"
        )
        addManualModelButton.title = L10n.Settings.addAIProviderAddManualModel
        addManualModelButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addManualModelButton.imagePosition = .imageLeading
        addManualModelButton.target = self
        addManualModelButton.action = #selector(addManualModelPressed(_:))
        addManualModelButton.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.addManualModel")
        StacioDesignSystem.styleSheetButton(addManualModelButton)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.status")

        cancelButton.title = L10n.Settings.addAIProviderCancel
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.cancel")
        StacioDesignSystem.styleSheetButton(cancelButton)

        saveButton.title = L10n.Settings.addAIProviderSaveDraft
        saveButton.target = self
        saveButton.action = #selector(savePressed(_:))
        saveButton.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.save")
        StacioDesignSystem.styleSheetButton(saveButton, isDefault: true)
    }

    private func configureTextField(
        _ field: NSTextField,
        identifier: String,
        placeholder: String
    ) {
        field.placeholderString = placeholder
        field.delegate = self
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier(identifier)
        StacioDesignSystem.styleTextField(field)
    }

    private func configureModelTable() {
        let enabledColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabledColumn.title = ""
        enabledColumn.width = 34
        let modelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        modelColumn.title = L10n.Settings.model
        modelColumn.width = 330
        let defaultColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("default"))
        defaultColumn.title = ""
        defaultColumn.width = 42
        modelTableView.addTableColumn(enabledColumn)
        modelTableView.addTableColumn(modelColumn)
        modelTableView.addTableColumn(defaultColumn)
        modelTableView.headerView = nil
        modelTableView.rowHeight = 30
        modelTableView.delegate = self
        modelTableView.dataSource = self
        modelTableView.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.modelTable")
        StacioDesignSystem.styleTable(modelTableView)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    private func reloadModelList() {
        let models = visibleModels
        modelTableView.reloadData()
        modelEmptyStateLabel.stringValue = draft.models.isEmpty
            ? L10n.Settings.addAIProviderNoModels
            : L10n.Settings.addAIProviderNoMatchingModels
        modelEmptyStateLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        modelEmptyStateLabel.isHidden = models.isEmpty == false
    }

    private func render() {
        displayNameField.stringValue = draft.displayName
        baseURLField.stringValue = draft.baseURL
        apiKeyField.stringValue = draft.apiKey
        saveButton.isEnabled = canSave && !isSaving && !didClose
        profilePopup.isEnabled = !isSaving && !didClose
        displayNameField.isEnabled = !isSaving && !didClose
        baseURLField.isEnabled = !isSaving && !didClose
        apiKeyField.isEnabled = !isSaving && !didClose
        let noCredential = draft.descriptor?.permitsNoCredential == true
            || draft.descriptor?.authenticationKind == CatalogAuthenticationKind.none
        apiKeyGridRow?.isHidden = noCredential || draft.descriptor == nil

        let discoveryStrategy = draft.descriptor?.modelDiscoveryStrategy
        fetchModelsButton.isHidden = discoveryStrategy == .manualOnly
            || discoveryStrategy == .unavailable
            || discoveryStrategy == .cliManaged
            || draft.descriptor == nil
        fetchModelsButton.title = noCredential
            ? L10n.Settings.addAIProviderSaveAndFetchModels
            : L10n.Settings.addAIProviderSaveCredentialAndFetchModels
        fetchModelsButton.isEnabled = canFetchModels && !didClose

        let websiteAction = primaryWebsiteAction
        websiteGridRow?.isHidden = websiteAction == nil
        websiteButton.title = websiteAction?.title ?? L10n.Settings.addAIProviderOfficialEntry
        websiteHostLabel.stringValue = websiteAction?.descriptor?.url.host ?? ""

        let permitsManualModels = draft.descriptor?.allowsManualModelIDs == true
        manualModelRow.isHidden = !permitsManualModels
        addManualModelButton.isEnabled = permitsManualModels && !isFetching && !isSaving && !didClose
        reloadModelList()
        if statusLabel.stringValue.isEmpty {
            statusLabel.stringValue = draft.descriptor == nil
                ? L10n.Settings.addAIProviderChooseProviderHint
                : draft.models.isEmpty
                ? L10n.Settings.addAIProviderReady
                : "\(L10n.Settings.addAIProviderFetchSucceeded) \(draft.models.count)"
        }
    }

    private func invalidateAndClose() {
        guard !didClose else { return }
        didClose = true
        let shouldNotifyCancel = !didFinish
        didFinish = true
        activeFetchRequest = nil
        isFetching = false
        isSaving = false
        saveRequestToken = nil
        stagingOwner = nil
        persistenceGate.close()
        mainExecutor { [weak self] in
            self?.render()
        }
        let coordinator = UncheckedAddAIProviderMutationCoordinator(mutationCoordinator)
        let gate = persistenceGate
        let registry = stagingRegistry
        let cleanupRetry = AddAIProviderStagingCleanupRetry.shared
        backgroundExecutor {
            do {
                try gate.cleanupAll { staleOwner in
                    try cleanupAddAIProviderStaging(
                        owner: staleOwner,
                        coordinator: coordinator.value,
                        registry: registry,
                        gate: gate
                    )
                }
                if registry.isEmpty == false {
                    cleanupRetry.enqueue(
                        gate: gate,
                        registry: registry,
                        coordinator: coordinator.value
                    )
                }
            } catch {
                cleanupRetry.enqueue(
                    gate: gate,
                    registry: registry,
                    coordinator: coordinator.value
                )
            }
        }
        if shouldNotifyCancel, let onCancel {
            onCancel()
        }
    }

    private var hasValidRequiredFields: Bool {
        guard draft.descriptor != nil else { return false }
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty == false
            && OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: baseURL) != nil
    }

    private var canSave: Bool {
        !isFetching && !isSaving && !didClose && hasValidRequiredFields
    }

    private var canFetchModels: Bool {
        guard !isFetching, !isSaving, !didClose,
              hasValidRequiredFields,
              let descriptor = draft.descriptor,
              descriptor.modelDiscoveryStrategy == .openAIModels
        else {
            return false
        }
        if descriptor.requiresCredential {
            return !draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var primaryWebsiteAction: WebsiteActionEntry? {
        runtimeCatalog.primaryWebsiteAction(ownerCatalogID: draft.descriptor?.catalogID)
    }

    private func syncDraftFromFields() {
        let previousInput = currentFetchInput
        let previousOrigin = AIProviderCredentialOriginPolicy.normalizedOrigin(
            forBaseURL: draft.baseURL
        )
        draft.displayName = displayNameField.stringValue
        draft.baseURL = baseURLField.stringValue
        draft.apiKey = apiKeyField.stringValue
        if previousOrigin != AIProviderCredentialOriginPolicy.normalizedOrigin(
            forBaseURL: draft.baseURL
        ) {
            draft.confirmedCredentialOrigin = nil
        }
        invalidateFetchStateIfNeeded(previousInput: previousInput)
    }

    private var currentFetchInput: FetchInputSnapshot {
        FetchInputSnapshot(
            catalogID: draft.descriptor?.catalogID,
            baseURL: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var visibleModels: [AIProviderModelConfiguration] {
        let query = modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            return draft.models
        }
        return draft.models.filter { model in
            model.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func invalidateFetchStateIfNeeded(previousInput: FetchInputSnapshot) {
        guard previousInput != currentFetchInput else {
            return
        }
        invalidateFetchState()
    }

    private func invalidateFetchState() {
        let oldOwner = stagingOwner
        persistenceGate.invalidate(owner: oldOwner)
        stagingOwner = nil
        activeFetchRequest = nil
        saveRequestToken = nil
        completedFetchInput = nil
        persistedCredentialInput = nil
        hasPersistedDraft = false
        hasPersistedCredential = false
        isFetching = false
        isSaving = false
        draft.lastModelSyncAt = nil
        for index in draft.models.indices where !draft.models[index].isManual {
            draft.models[index].wasReturnedByLatestCatalog = false
            draft.models[index].isEnabled = false
        }
        if let defaultModelID = draft.defaultModelID,
           draft.models.contains(where: { $0.id == defaultModelID && $0.isEnabled }) == false {
            draft.defaultModelID = nil
        }
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = L10n.Settings.addAIProviderReady
    }

    private func applyCatalogEntry(_ descriptor: NativeRuntimeCatalogEntry?) {
        invalidateFetchState()
        draft.confirmedCredentialOrigin = nil
        draft.descriptor = descriptor
        draft.displayName = descriptor?.displayName ?? ""
        draft.baseURL = descriptor?.suggestedBaseURL ?? ""
        draft.apiKey = ""
        draft.models = []
        draft.defaultModelID = nil
        draft.lastModelSyncAt = nil
        modelSearchQuery = ""
        modelSearchField.stringValue = ""
        statusLabel.stringValue = ""
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        let selectedIndex = sender.indexOfSelectedItem - 1
        let descriptor = catalogEntries.indices.contains(selectedIndex)
            ? catalogEntries[selectedIndex]
            : nil
        applyCatalogEntry(descriptor)
        render()
    }

    @objc private func openWebsitePressed(_ sender: NSButton) {
        guard let url = primaryWebsiteAction?.descriptor?.url else { return }
        _ = websiteOpener(url)
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) {
        syncDraftFromFields()
        render()
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSSearchField,
           field === modelSearchField {
            modelSearchQuery = field.stringValue
            reloadModelList()
            return
        }
        syncDraftFromFields()
        saveButton.isEnabled = canSave
        fetchModelsButton.isEnabled = canFetchModels
    }

    @objc private func modelSearchChanged(_ sender: NSSearchField) {
        modelSearchQuery = sender.stringValue
        reloadModelList()
    }

    @objc private func fetchModelsPressed(_ sender: NSButton) {
        fetchModels()
    }

    private func fetchModels() {
        syncDraftFromFields()
        guard canFetchModels,
              let descriptor = draft.descriptor,
              var provider = draft.makeConfiguration(id: providerIDForMutation()),
              !didClose
        else {
            activeFetchRequest = nil
            completedFetchInput = nil
            isFetching = false
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = hasValidRequiredFields
                ? L10n.Settings.addAIProviderCredentialRequired
                : L10n.Settings.addAIProviderInvalidRequiredFields
            render()
            return
        }

        let typedAPIKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if descriptor.requiresCredential,
           let origin = AIProviderCredentialOriginPolicy.pendingConfirmationOrigin(
               for: provider,
               runtimeCatalog: runtimeCatalog
           ) {
            let request = AIProviderCredentialOriginConfirmationRequest(
                providerName: provider.displayName,
                origin: origin,
                credentialPurpose: L10n.Settings.aiCredentialOriginModelDiscoveryPurpose
            )
            guard credentialOriginConfirmationHandler(request) else {
                activeFetchRequest = nil
                completedFetchInput = nil
                isFetching = false
                statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
                statusLabel.stringValue = L10n.Settings.aiCredentialOriginCancelled
                render()
                return
            }
            draft.confirmedCredentialOrigin = origin
            provider.confirmedCredentialOrigin = origin
        }
        let owner = UUID()
        persistenceGate.invalidate(owner: stagingOwner)
        stagingOwner = owner
        guard persistenceGate.install(owner: owner) else { return }
        let input = currentFetchInput
        let existingModels = draft.models
        let existingDefaultModelID = draft.defaultModelID
        let request = FetchRequest(token: UUID(), owner: owner, input: input)
        activeFetchRequest = request
        completedFetchInput = nil
        isFetching = true
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = L10n.Settings.addAIProviderFetching
        render()

        let credentialUpdate: AIProviderAPIKeyUpdate = descriptor.requiresCredential
            ? .replace(typedAPIKey)
            : .unchanged
        let loader = UncheckedAddAIProviderCatalogLoader(modelCatalogLoader)
        let coordinator = UncheckedAddAIProviderMutationCoordinator(mutationCoordinator)
        let gate = persistenceGate
        let registry = stagingRegistry
        backgroundExecutor { [weak self] in
            let result: Result<[AIModelCatalogEntry], Error> = Result {
                guard let persistedAPIKey = try gate.withExclusive(
                    owner: owner,
                    cleanup: { staleOwner in
                        try cleanupAddAIProviderStaging(
                            owner: staleOwner,
                            coordinator: coordinator.value,
                            registry: registry,
                            gate: gate
                        )
                    },
                    operation: {
                        _ = try coordinator.value.saveProvider(
                            provider,
                            apiKeyUpdate: credentialUpdate
                        )
                        let key: String?
                        if descriptor.requiresCredential {
                            key = try coordinator.value.readAPIKey(for: provider.id)
                            guard key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                                throw AIProviderSheetValidationError.credentialNotPersisted
                            }
                        } else {
                            key = nil
                        }
                        registry.insert(
                            AddAIProviderStagedRecord(
                                providerID: provider.id,
                                credentialBacked: descriptor.requiresCredential
                            ),
                            owner: owner
                        )
                        guard gate.isCurrent(owner) else {
                            try cleanupAddAIProviderStaging(
                                owner: owner,
                                coordinator: coordinator.value,
                                registry: registry,
                                gate: gate
                            )
                            throw AIProviderSheetValidationError.requestCancelled
                        }
                        return key
                    }
                ) else {
                    throw AIProviderSheetValidationError.requestCancelled
                }
                guard gate.isCurrent(owner) else {
                    throw AIProviderSheetValidationError.requestCancelled
                }
                let entries = try loader.value.listModelEntries(
                    for: provider,
                    apiKey: persistedAPIKey
                )
                guard gate.isCurrent(owner) else {
                    throw AIProviderSheetValidationError.requestCancelled
                }
                guard let mergedProvider = Self.providerByMerging(
                    provider,
                    entries: entries,
                    existingModels: existingModels,
                    existingDefaultModelID: existingDefaultModelID
                ) else {
                    return entries
                }
                guard let _ = try gate.withExclusive(
                    owner: owner,
                    cleanup: { staleOwner in
                        try cleanupAddAIProviderStaging(
                            owner: staleOwner,
                            coordinator: coordinator.value,
                            registry: registry,
                            gate: gate
                        )
                    },
                    operation: {
                        let envelope = try coordinator.value.saveProvider(
                            mergedProvider,
                            apiKeyUpdate: .unchanged
                        )
                        guard gate.isCurrent(owner) else {
                            try cleanupAddAIProviderStaging(
                                owner: owner,
                                coordinator: coordinator.value,
                                registry: registry,
                                gate: gate
                            )
                            throw AIProviderSheetValidationError.requestCancelled
                        }
                        _ = envelope
                        return true
                    }
                ) else {
                    throw AIProviderSheetValidationError.requestCancelled
                }
                return entries
            }
            self?.mainExecutor { [weak self] in
                self?.handleFetchResult(
                    result,
                    request: request,
                    apiKey: typedAPIKey,
                    descriptor: descriptor
                )
            }
        }
    }

    private static func providerByMerging(
        _ provider: AIProviderConfiguration,
        entries: [AIModelCatalogEntry],
        existingModels: [AIProviderModelConfiguration],
        existingDefaultModelID: String?
    ) -> AIProviderConfiguration? {
        let merged = AIProviderModelCatalogMerger.merge(
            existing: existingModels,
            fetchedEntries: entries
        )
        guard merged.contains(where: \.wasReturnedByLatestCatalog) else { return nil }
        var result = provider
        result.models = merged
        result.defaultModelID = existingDefaultModelID
        if let defaultModelID = result.defaultModelID,
           merged.contains(where: {
               $0.id == defaultModelID && $0.isEnabled && !$0.isManual
           }) == false {
            result.defaultModelID = nil
        }
        result.lastModelSyncAt = Date()
        return result
    }

    private func handleFetchResult(
        _ result: Result<[AIModelCatalogEntry], Error>,
        request: FetchRequest,
        apiKey: String,
        descriptor: NativeRuntimeCatalogEntry
    ) {
        guard activeFetchRequest == request,
              currentFetchInput == request.input,
              persistenceGate.isCurrent(request.owner),
              !didClose
        else {
            return
        }
        activeFetchRequest = nil
        isFetching = false
        switch result {
        case let .success(entries):
            let existingModels = draft.models
            let mergedModels = AIProviderModelCatalogMerger.merge(
                existing: existingModels,
                fetchedEntries: entries
            )
            guard mergedModels.contains(where: \.wasReturnedByLatestCatalog) else {
                applyFetchFailure(AIAssistantProviderError.invalidResponse, apiKey: apiKey)
                render()
                return
            }
            completedFetchInput = request.input
            draft.models = mergedModels
            if let defaultModelID = draft.defaultModelID,
               draft.models.contains(where: {
                   $0.id == defaultModelID && $0.isEnabled && !$0.isManual
               }) == false {
                draft.defaultModelID = nil
            }
            draft.lastModelSyncAt = Date()
            statusLabel.textColor = StacioDesignSystem.theme.successColor
            statusLabel.stringValue = "\(L10n.Settings.addAIProviderFetchSucceeded) \(draft.models.count)"
            hasPersistedDraft = true
            hasPersistedCredential = descriptor.requiresCredential
            persistedCredentialInput = request.input
        case let .failure(error):
            applyFetchFailure(error, apiKey: apiKey)
        }
        render()
    }

    private func applyFetchFailure(_ error: Error, apiKey: String) {
        completedFetchInput = nil
        draft.lastModelSyncAt = nil
        for index in draft.models.indices where !draft.models[index].isManual {
            draft.models[index].wasReturnedByLatestCatalog = false
            draft.models[index].isEnabled = false
        }
        if let defaultModelID = draft.defaultModelID,
           draft.models.contains(where: { $0.id == defaultModelID && $0.isEnabled }) == false {
            draft.defaultModelID = nil
        }
        statusLabel.textColor = StacioDesignSystem.theme.dangerColor
        statusLabel.stringValue = L10n.Settings.addAIProviderFetchFailedPrefix
            + redactedMessage(for: error, apiKey: apiKey)
    }

    @objc private func addManualModelPressed(_ sender: NSButton) {
        addManualModel(manualModelField.stringValue)
    }

    private func addManualModel(_ rawModelID: String) {
        guard !isFetching, draft.descriptor?.allowsManualModelIDs == true else { return }
        let modelID = AppSettings.normalizedAIModelName(rawModelID)
        guard modelID.isEmpty == false else {
            return
        }
        if draft.models.contains(where: { $0.id == modelID }) == false {
            draft.models.append(
                AIProviderModelConfiguration(
                    id: modelID,
                    isEnabled: false,
                    isManual: true,
                    wasReturnedByLatestCatalog: false
                )
            )
        }
        manualModelField.stringValue = ""
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = ""
        render()
    }

    @objc private func savePressed(_ sender: NSButton) {
        saveDraft()
    }

    private func saveDraft() {
        syncDraftFromFields()
        guard canSave, !didClose, !isSaving else {
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.Settings.addAIProviderInvalidRequiredFields
            render()
            return
        }

        let id = providerIDForMutation()
        guard let provider = draft.makeConfiguration(id: id) else {
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.Settings.addAIProviderInvalidRequiredFields
            render()
            return
        }
        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let requiresCredential = draft.descriptor?.requiresCredential == true
        let shouldPersistCredential = requiresCredential
            && !apiKey.isEmpty
            && (hasPersistedCredential == false || persistedCredentialInput != currentFetchInput)
        let credentialUpdate: AIProviderAPIKeyUpdate
        if shouldPersistCredential {
            credentialUpdate = .replace(apiKey)
        } else if apiKey.isEmpty, hasPersistedCredential {
            // Model discovery temporarily persists credentials. If the user
            // clears the field or switches to another catalog entry before
            // saving, `.unchanged` would silently attach the old provider's
            // secret to the new configuration sharing this draft UUID.
            credentialUpdate = .remove
        } else {
            credentialUpdate = .unchanged
        }
        let owner = stagingOwner ?? UUID()
        if stagingOwner == nil {
            stagingOwner = owner
            guard persistenceGate.install(owner: owner) else { return }
        }
        let input = currentFetchInput
        let token = UUID()
        saveRequestToken = token
        isSaving = true
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = L10n.Settings.addAIProviderSaving
        render()

        let coordinator = UncheckedAddAIProviderMutationCoordinator(mutationCoordinator)
        let gate = persistenceGate
        let registry = stagingRegistry
        backgroundExecutor { [weak self] in
            let result: Result<AIProviderSettingsEnvelope, Error> = Result {
                guard let envelope = try gate.withExclusive(
                    owner: owner,
                    cleanup: { staleOwner in
                        try cleanupAddAIProviderStaging(
                            owner: staleOwner,
                            coordinator: coordinator.value,
                            registry: registry,
                            gate: gate
                        )
                    },
                    operation: {
                        let envelope = try coordinator.value.saveProvider(
                            provider,
                            apiKeyUpdate: credentialUpdate
                        )
                        let existingRecord = registry.record(for: owner)
                        registry.insert(
                            AddAIProviderStagedRecord(
                                providerID: id,
                                credentialBacked: existingRecord?.credentialBacked == true
                                    || (requiresCredential && !apiKey.isEmpty)
                            ),
                            owner: owner
                        )
                        guard gate.markCommitted(owner, providerID: id) else {
                            throw AIProviderSheetValidationError.requestCancelled
                        }
                        registry.remove(owner: owner)
                        return envelope
                    }
                ) else {
                    throw AIProviderSheetValidationError.requestCancelled
                }
                return envelope
            }
            self?.mainExecutor { [weak self] in
                self?.handleSaveResult(
                    result,
                    providerID: id,
                    token: token,
                    input: input,
                    apiKey: apiKey
                )
            }
        }
    }

    private func handleSaveResult(
        _ result: Result<AIProviderSettingsEnvelope, Error>,
        providerID: UUID,
        token: UUID,
        input: FetchInputSnapshot,
        apiKey: String
    ) {
        guard saveRequestToken == token,
              !didClose,
              currentFetchInput == input
        else { return }
        isSaving = false
        saveRequestToken = nil
        switch result {
        case .success:
            stagingOwner = nil
            hasPersistedDraft = false
            hasPersistedCredential = !apiKey.isEmpty
            persistedCredentialInput = apiKey.isEmpty ? nil : input
            didFinish = true
            statusLabel.textColor = StacioDesignSystem.theme.successColor
            statusLabel.stringValue = L10n.Settings.addAIProviderSaved
            onSaved?(providerID)
        case let .failure(error):
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.Settings.addAIProviderSaveFailedPrefix
                + redactedMessage(for: error, apiKey: apiKey)
        }
        render()
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        invalidateAndClose()
    }

    private func providerIDForMutation() -> UUID {
        if let providerID {
            return providerID
        }
        let generated = providerIDGenerator()
        providerID = generated
        return generated
    }

    private func redactedMessage(for error: Error, apiKey: String?) -> String {
        var message = RuntimeDiagnosticFormatter.userMessage(for: error)
        let normalizedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedKey.isEmpty == false {
            message = message.replacingOccurrences(
                of: normalizedKey,
                with: L10n.Diagnostics.redactedCredential
            )
        }
        return message
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleModels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let models = visibleModels
        guard models.indices.contains(row) else { return nil }
        let model = models[row]
        guard let modelIndex = draft.models.firstIndex(where: { $0.id == model.id }) else {
            return nil
        }
        switch tableColumn?.identifier.rawValue {
        case "enabled":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(modelEnabledChanged(_:)))
            button.tag = modelIndex
            button.state = model.isEnabled ? .on : .off
            button.isEnabled = !isFetching && !isSaving && !didClose
                && !model.isManual && model.wasReturnedByLatestCatalog
            button.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.model.enabled.\(model.id)")
            return button
        case "default":
            let button = NSButton()
            button.title = ""
            button.image = NSImage(
                systemSymbolName: model.id == draft.defaultModelID ? "star.fill" : "star",
                accessibilityDescription: L10n.Settings.model
            )
            button.imagePosition = .imageOnly
            button.tag = modelIndex
            button.target = self
            button.action = #selector(defaultModelChanged(_:))
            button.isEnabled = !isFetching && !isSaving && !didClose
                && !model.isManual && model.wasReturnedByLatestCatalog
            button.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.model.default.\(model.id)")
            StacioDesignSystem.styleIconButton(button)
            return button
        default:
            let label = NSTextField(labelWithString: model.id)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = model.id
            label.textColor = StacioDesignSystem.theme.primaryTextColor
            return label
        }
    }

    @objc private func modelEnabledChanged(_ sender: NSButton) {
        guard !isFetching, !isSaving, !didClose,
              draft.models.indices.contains(sender.tag),
              !draft.models[sender.tag].isManual,
              draft.models[sender.tag].wasReturnedByLatestCatalog else {
            return
        }
        draft.models[sender.tag].isEnabled = sender.state == .on
        if draft.models[sender.tag].isEnabled,
           draft.defaultModelID == nil {
            draft.defaultModelID = draft.models[sender.tag].id
        }
        if draft.models[sender.tag].isEnabled == false,
           draft.defaultModelID == draft.models[sender.tag].id {
            draft.defaultModelID = nil
        }
        render()
    }

    @objc private func defaultModelChanged(_ sender: NSButton) {
        guard !isFetching, !isSaving, !didClose,
              draft.models.indices.contains(sender.tag),
              !draft.models[sender.tag].isManual,
              draft.models[sender.tag].wasReturnedByLatestCatalog else {
            return
        }
        draft.models[sender.tag].isEnabled = true
        draft.defaultModelID = draft.models[sender.tag].id
        render()
    }
}

extension AddAIProviderSheetController {
    var nameForTesting: String { draft.displayName }
    var baseURLForTesting: String { draft.baseURL }
    var statusTextForTesting: String { statusLabel.stringValue }
    var canSaveForTesting: Bool { canSave }
    var modelIDsForTesting: [String] { draft.models.map(\.id) }
    var defaultModelIDForTesting: String? { draft.defaultModelID }
    var catalogIDForTesting: String? { draft.descriptor?.catalogID }
    var modelEnabledStatesForTesting: [Bool] { draft.models.map(\.isEnabled) }
    var isAPIKeyHiddenForTesting: Bool { apiKeyGridRow?.isHidden ?? apiKeyField.isHidden }
    var isManualModelEntryHiddenForTesting: Bool { manualModelRow.isHidden }
    var canFetchModelsForTesting: Bool { canFetchModels }
    var fetchModelsButtonEnabledForTesting: Bool { fetchModelsButton.isEnabled }
    var websiteButtonTitleForTesting: String? {
        websiteGridRow?.isHidden == true ? nil : websiteButton.title
    }

    func setDraft(name: String, baseURL: String, apiKey: String) {
        if draft.descriptor == nil,
           let descriptor = catalogEntries.first(where: {
               $0.modelDiscoveryStrategy == .openAIModels && $0.requiresCredential
           }) {
            applyCatalogEntry(descriptor)
            profilePopup.selectItem(at: (catalogEntries.firstIndex(of: descriptor) ?? -1) + 1)
        }
        let previousInput = currentFetchInput
        let previousOrigin = AIProviderCredentialOriginPolicy.normalizedOrigin(
            forBaseURL: draft.baseURL
        )
        draft.displayName = name
        draft.baseURL = baseURL
        draft.apiKey = apiKey
        if previousOrigin != AIProviderCredentialOriginPolicy.normalizedOrigin(forBaseURL: baseURL) {
            draft.confirmedCredentialOrigin = nil
        }
        invalidateFetchStateIfNeeded(previousInput: previousInput)
        if isViewLoaded {
            render()
        }
    }

    func fetchModelsForTesting() {
        fetchModels()
    }

    func selectProviderForTesting(catalogID: String) {
        guard let index = catalogEntries.firstIndex(where: { $0.catalogID == catalogID }) else {
            return
        }
        profilePopup.selectItem(at: index + 1)
        applyCatalogEntry(catalogEntries[index])
        render()
    }

    func openWebsiteForTesting() {
        openWebsitePressed(websiteButton)
    }

    func saveForTesting() {
        saveDraft()
    }

    func cancelForTesting() {
        cancelPressed(cancelButton)
    }

    func addManualModelForTesting(_ modelID: String) {
        addManualModel(modelID)
    }

    func setDefaultModelForTesting(_ modelID: String) {
        if let index = draft.models.firstIndex(where: { $0.id == modelID }),
           !draft.models[index].isManual {
            draft.models[index].isEnabled = true
            draft.defaultModelID = modelID
        }
        render()
    }

    func setModelEnabledForTesting(_ modelID: String, isEnabled: Bool) {
        if let index = draft.models.firstIndex(where: { $0.id == modelID }),
           !draft.models[index].isManual {
            draft.models[index].isEnabled = isEnabled
            if isEnabled, draft.defaultModelID == nil {
                draft.defaultModelID = modelID
            } else if isEnabled == false, draft.defaultModelID == modelID {
                draft.defaultModelID = nil
            }
        }
        render()
    }

    func clearDefaultModelForTesting() {
        draft.defaultModelID = nil
        render()
    }
}

private enum AIProviderSheetValidationError: Error {
    case invalidDraft
    case credentialNotPersisted
    case requestCancelled
}

private struct AddAIProviderStagedRecord: Sendable {
    let providerID: UUID
    let credentialBacked: Bool
}

private func cleanupAddAIProviderStaging(
    owner: UUID,
    coordinator: AIProviderMutationCoordinating,
    registry: AddAIProviderStagingRegistry,
    gate: AddAIProviderPersistenceGate
) throws {
    guard let record = registry.record(for: owner) else {
        gate.remove(owner)
        return
    }
    guard !gate.isProviderCommitted(record.providerID, excluding: owner) else {
        registry.remove(owner: owner)
        gate.remove(owner)
        return
    }
    guard !registry.hasOtherRecord(forProviderID: record.providerID, excluding: owner) else {
        // Another owner now owns the same provider ID. It is responsible for
        // deleting or committing that configuration; retaining this record
        // would make the owner unreachable and leak the staged credential.
        registry.remove(owner: owner)
        gate.remove(owner)
        return
    }
    if record.credentialBacked {
        _ = try coordinator.deleteProvider(id: record.providerID)
    } else {
        _ = try coordinator.deleteProviderConfiguration(id: record.providerID)
    }
    registry.remove(owner: owner)
    gate.remove(owner)
}

/// Coordinates persistence work that may outlive the AppKit controller. The
/// state lock is intentionally independent from the operation lock: closing a
/// sheet must invalidate work immediately, even while a network request is in
/// progress. The operation lock then serializes cleanup and writes so an old
/// staged owner cannot delete a newer owner that reuses the draft UUID.
private final class AddAIProviderPersistenceGate: @unchecked Sendable {
    private enum OwnerState {
        case active
        case invalidated
        case cleaning
        case committed
        case cleaned
    }

    private let stateLock = NSLock()
    private let operationLock = NSLock()
    private var states: [UUID: OwnerState] = [:]
    private var currentOwner: UUID?
    private var isClosed = false
    private var committedProviderIDs: Set<UUID> = []

    func install(owner: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return false }
        if let currentOwner,
           states[currentOwner] == .active {
            states[currentOwner] = .invalidated
        }
        states[owner] = .active
        currentOwner = owner
        return true
    }

    func invalidate(owner: UUID?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let owner else { return }
        if states[owner] == .active {
            states[owner] = .invalidated
        }
        if currentOwner == owner {
            currentOwner = nil
        }
    }

    func close() {
        stateLock.lock()
        isClosed = true
        if let currentOwner,
           states[currentOwner] == .active {
            states[currentOwner] = .invalidated
        }
        currentOwner = nil
        stateLock.unlock()
    }

    func isCurrent(_ owner: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return !isClosed && currentOwner == owner && states[owner] == .active
    }

    func markCommitted(_ owner: UUID, providerID: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard states[owner] == .active,
              !isClosed,
              currentOwner == owner
        else {
            return false
        }
        states[owner] = .committed
        committedProviderIDs.insert(providerID)
        currentOwner = nil
        return true
    }

    func isProviderCommitted(_ providerID: UUID, excluding owner: UUID?) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard committedProviderIDs.contains(providerID) else { return false }
        // A committed provider is protected even when the old staging owner is
        // the one currently being cleaned. `owner` is accepted to keep the
        // call site explicit about the attribution being checked.
        _ = owner
        return true
    }

    func remove(_ owner: UUID) {
        stateLock.lock()
        states.removeValue(forKey: owner)
        if currentOwner == owner {
            currentOwner = nil
        }
        stateLock.unlock()
    }

    func withExclusive<T>(
        owner: UUID,
        cleanup: (UUID) throws -> Void,
        operation: () throws -> T
    ) rethrows -> T? {
        operationLock.lock()
        defer { operationLock.unlock() }
        try cleanInvalidatedOwners(excluding: owner, cleanup: cleanup)
        guard isCurrent(owner) else { return nil }
        return try operation()
    }

    func cleanupAll(cleanup: (UUID) throws -> Void) rethrows {
        operationLock.lock()
        defer { operationLock.unlock() }
        try cleanInvalidatedOwners(excluding: nil, cleanup: cleanup)
    }

    private func cleanInvalidatedOwners(
        excluding excludedOwner: UUID?,
        cleanup: (UUID) throws -> Void
    ) rethrows {
        let candidates: [UUID] = {
            stateLock.lock()
            defer { stateLock.unlock() }
            let candidates = states.compactMap { owner, state -> UUID? in
                guard owner != excludedOwner, state == .invalidated else { return nil }
                return owner
            }
            candidates.forEach { states[$0] = .cleaning }
            return candidates
        }()

        for owner in candidates {
            do {
                try cleanup(owner)
                stateLock.lock()
                states.removeValue(forKey: owner)
                stateLock.unlock()
            } catch {
                stateLock.lock()
                states[owner] = .invalidated
                stateLock.unlock()
                throw error
            }
        }
    }
}

private final class AddAIProviderStagingRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [UUID: AddAIProviderStagedRecord] = [:]

    func insert(_ record: AddAIProviderStagedRecord, owner: UUID) {
        lock.lock()
        records[owner] = record
        lock.unlock()
    }

    func record(for owner: UUID) -> AddAIProviderStagedRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records[owner]
    }

    func remove(owner: UUID) {
        lock.lock()
        records.removeValue(forKey: owner)
        lock.unlock()
    }

    func hasOtherRecord(forProviderID providerID: UUID, excluding owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { candidateOwner, record in
            candidateOwner != owner && record.providerID == providerID
        }
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.isEmpty
    }
}

/// Keeps staged-provider cleanup alive after the sheet has disappeared. A
/// Keychain-backed temporary credential must not depend on the controller (or
/// its test executor) remaining alive for cleanup to finish.
private final class AddAIProviderStagingCleanupRetry: @unchecked Sendable {
    static let shared = AddAIProviderStagingCleanupRetry()

    private final class Pending: @unchecked Sendable {
        let gate: AddAIProviderPersistenceGate
        let registry: AddAIProviderStagingRegistry
        let coordinator: AIProviderMutationCoordinating
        var scheduled = false
        var inFlight = false
        var attempt = 0

        init(
            gate: AddAIProviderPersistenceGate,
            registry: AddAIProviderStagingRegistry,
            coordinator: AIProviderMutationCoordinating
        ) {
            self.gate = gate
            self.registry = registry
            self.coordinator = coordinator
        }
    }

    private let lock = NSLock()
    private var pending: [ObjectIdentifier: Pending] = [:]

    func enqueue(
        gate: AddAIProviderPersistenceGate,
        registry: AddAIProviderStagingRegistry,
        coordinator: AIProviderMutationCoordinating
    ) {
        let key = ObjectIdentifier(gate)
        let shouldSchedule: Bool
        let record: Pending
        lock.lock()
        if let existing = pending[key] {
            record = existing
            shouldSchedule = !existing.scheduled && !existing.inFlight
        } else {
            let created = Pending(
                gate: gate,
                registry: registry,
                coordinator: coordinator
            )
            pending[key] = created
            record = created
            shouldSchedule = true
        }
        if shouldSchedule {
            record.scheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.global(qos: .utility).async { [weak self, weak record] in
            self?.run(key: key, record: record)
        }
    }

    private func run(key: ObjectIdentifier, record: Pending?) {
        guard let record else { return }
        lock.lock()
        guard pending[key] === record, record.scheduled, !record.inFlight else {
            lock.unlock()
            return
        }
        record.scheduled = false
        record.inFlight = true
        lock.unlock()

        do {
            try record.gate.cleanupAll { staleOwner in
                try cleanupAddAIProviderStaging(
                    owner: staleOwner,
                    coordinator: record.coordinator,
                    registry: record.registry,
                    gate: record.gate
                )
            }
            finish(key: key, record: record, retry: !record.registry.isEmpty)
        } catch {
            // Keep retrying with a bounded backoff. This covers transient
            // Keychain lock/save failures without spinning the utility queue.
            finish(key: key, record: record, retry: true)
        }
    }

    private func finish(key: ObjectIdentifier, record: Pending, retry: Bool) {
        lock.lock()
        guard pending[key] === record else {
            lock.unlock()
            return
        }
        record.inFlight = false
        guard retry else {
            pending.removeValue(forKey: key)
            lock.unlock()
            return
        }
        record.attempt += 1
        let delay: TimeInterval
        switch record.attempt {
        case 1: delay = 0.1
        case 2: delay = 0.5
        case 3: delay = 2
        default: delay = 10
        }
        record.scheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self, weak record] in
            self?.run(key: key, record: record)
        }
    }
}

private final class UncheckedAddAIProviderTask: @unchecked Sendable {
    let operation: () -> Void

    init(_ operation: @escaping () -> Void) {
        self.operation = operation
    }
}

private final class UncheckedAddAIProviderCatalogLoader: @unchecked Sendable {
    let value: AIModelCatalogLoading

    init(_ value: AIModelCatalogLoading) {
        self.value = value
    }
}

private final class UncheckedAddAIProviderMutationCoordinator: @unchecked Sendable {
    let value: AIProviderMutationCoordinating

    init(_ value: AIProviderMutationCoordinating) {
        self.value = value
    }
}
