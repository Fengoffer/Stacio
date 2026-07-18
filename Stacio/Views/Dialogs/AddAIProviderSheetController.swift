import AppKit
import Foundation

struct AddAIProviderDraft {
    var profile: AIProviderProfile
    var displayName: String
    var baseURL: String
    var apiKey: String
    var models: [AIProviderModelConfiguration]
    var defaultModelID: String?

    func makeConfiguration(id: UUID) -> AIProviderConfiguration {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModels = AIProviderSettingsNormalizer.normalized(
            AIProviderSettingsEnvelope(
                aiProviders: [
                    AIProviderConfiguration(
                        id: id,
                        profile: profile,
                        displayName: trimmedName,
                        baseURL: trimmedBaseURL,
                        models: models,
                        defaultModelID: defaultModelID,
                        compatibilityProtocol: .chatCompletions,
                        maxRetryCount: 1,
                        requestTimeoutSeconds: 45,
                        userAgent: "Stacio",
                        isEnabled: models.contains { $0.isEnabled } && defaultModelID != nil,
                        lastVerifiedAt: nil,
                        lastModelSyncAt: nil
                    )
                ],
                defaultAIProviderID: id
            )
        )
        return normalizedModels.aiProviders[0]
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
        let profile: AIProviderProfile
        let baseURL: String
        let apiKey: String
    }

    private struct FetchRequest: Equatable {
        let token: UUID
        let input: FetchInputSnapshot
    }

    var onSaved: ((UUID) -> Void)?
    var onCancel: (() -> Void)?

    private let providerIDGenerator: () -> UUID
    private let mutationCoordinator: AIProviderMutationCoordinating
    private let modelCatalogLoader: AIModelCatalogLoading
    private let backgroundExecutor: AIProviderTaskExecutor
    private let mainExecutor: AIProviderTaskExecutor

    private var providerID: UUID?
    private var activeFetchRequest: FetchRequest?
    private var completedFetchInput: FetchInputSnapshot?
    private var isFetching = false
    private var modelSearchQuery = ""
    private var draft = AddAIProviderDraft(
        profile: .openAICompatible,
        displayName: "",
        baseURL: "",
        apiKey: "",
        models: [],
        defaultModelID: nil
    )

    private let profilePopup = NSPopUpButton()
    private let displayNameField = NSTextField()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let fetchModelsButton = NSButton()
    private let modelSearchField = NSSearchField()
    private let modelTableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let manualModelField = NSTextField()
    private let addManualModelButton = NSButton()
    private let cancelButton = NSButton()
    private let saveButton = NSButton()

    init(
        providerIDGenerator: @escaping () -> UUID = UUID.init,
        mutationCoordinator: AIProviderMutationCoordinating,
        modelCatalogLoader: AIModelCatalogLoading,
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
        self.backgroundExecutor = backgroundExecutor
        self.mainExecutor = mainExecutor
        super.init(nibName: nil, bundle: nil)
        applyProfileTemplate(.openAICompatible)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = StacioAppearanceRefreshView(frame: NSRect(x: 0, y: 0, width: 560, height: 550))
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

        let form = NSGridView(views: [
            [makeLabel(L10n.Settings.addAIProviderTemplate), profilePopup],
            [makeLabel(L10n.Settings.addAIProviderDisplayName), displayNameField],
            [makeLabel(L10n.Settings.baseURL), baseURLField],
            [makeLabel(L10n.Settings.apiKey), apiKeyField]
        ])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.rowSpacing = 6
        form.columnSpacing = 12
        form.translatesAutoresizingMaskIntoConstraints = false

        let modelScrollView = NSScrollView()
        modelScrollView.translatesAutoresizingMaskIntoConstraints = false
        modelScrollView.drawsBackground = false
        modelScrollView.borderType = .bezelBorder
        modelScrollView.hasVerticalScroller = true
        modelScrollView.autohidesScrollers = true
        modelScrollView.documentView = modelTableView
        modelScrollView.setAccessibilityIdentifier("Stacio.Settings.addAIProvider.models")

        let manualRow = NSStackView(views: [manualModelField, addManualModelButton])
        manualRow.orientation = .horizontal
        manualRow.alignment = .centerY
        manualRow.spacing = 8

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
            manualRow,
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
            profilePopup.widthAnchor.constraint(equalToConstant: 320),
            displayNameField.widthAnchor.constraint(equalToConstant: 320),
            baseURLField.widthAnchor.constraint(equalToConstant: 320),
            apiKeyField.widthAnchor.constraint(equalToConstant: 320),
            fetchModelsButton.heightAnchor.constraint(equalToConstant: 30),
            modelSearchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelSearchField.heightAnchor.constraint(equalToConstant: 28),
            modelScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelScrollView.heightAnchor.constraint(equalToConstant: 120),
            manualModelField.widthAnchor.constraint(equalToConstant: 320),
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
            self?.modelTableView.reloadData()
        }
        view = root
        render()
    }

    private func configureControls() {
        AIProviderProfile.settingsMenuProfiles
            .filter(\.usesModelInterface)
            .forEach { profilePopup.addItem(withTitle: $0.displayName) }
        profilePopup.selectItem(withTitle: draft.profile.displayName)
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

        fetchModelsButton.title = L10n.Settings.addAIProviderFetchModels
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

        saveButton.title = L10n.Settings.addAIProviderSave
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

    private func render() {
        displayNameField.stringValue = draft.displayName
        baseURLField.stringValue = draft.baseURL
        apiKeyField.stringValue = draft.apiKey
        saveButton.isEnabled = canSave
        fetchModelsButton.isEnabled = isFetching == false && hasValidRequiredFields
        modelTableView.reloadData()
        if statusLabel.stringValue.isEmpty {
            statusLabel.stringValue = draft.models.isEmpty
                ? L10n.Settings.addAIProviderReady
                : "\(L10n.Settings.addAIProviderFetchSucceeded) \(draft.models.count)"
        }
    }

    private var hasValidRequiredFields: Bool {
        let name = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty == false
            && OpenAICompatibleAIAssistantProvider.normalizedBaseURL(from: baseURL) != nil
    }

    private var canSave: Bool {
        guard isFetching == false, hasValidRequiredFields else {
            return false
        }
        let enabledModels = draft.models.filter(\.isEnabled)
        let completedCurrentFetch = completedFetchInput == currentFetchInput
        if enabledModels.isEmpty {
            return completedCurrentFetch
        }
        guard let defaultModelID = draft.defaultModelID else {
            return false
        }
        guard enabledModels.contains(where: { $0.id == defaultModelID }) else {
            return false
        }
        return completedCurrentFetch || enabledModels.contains(where: \.isManual)
    }

    private func syncDraftFromFields() {
        let previousInput = currentFetchInput
        draft.displayName = displayNameField.stringValue
        draft.baseURL = baseURLField.stringValue
        draft.apiKey = apiKeyField.stringValue
        invalidateFetchStateIfNeeded(previousInput: previousInput)
    }

    private var currentFetchInput: FetchInputSnapshot {
        FetchInputSnapshot(
            profile: draft.profile,
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
        activeFetchRequest = nil
        completedFetchInput = nil
        isFetching = false
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = L10n.Settings.addAIProviderReady
    }

    private func applyProfileTemplate(_ profile: AIProviderProfile) {
        invalidateFetchState()
        draft.profile = profile
        draft.displayName = profile.displayName
        draft.baseURL = profile.defaultBaseURL ?? ""
        draft.models = AppSettings.normalizedAIModelList(profile.suggestedModels).map {
            AIProviderModelConfiguration(
                id: $0,
                isEnabled: true,
                isManual: false,
                wasReturnedByLatestCatalog: false
            )
        }
        draft.defaultModelID = profile.defaultModel.flatMap { defaultModel in
            draft.models.contains(where: { $0.id == defaultModel }) ? defaultModel : nil
        } ?? draft.models.first?.id
        modelSearchQuery = ""
        modelSearchField.stringValue = ""
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        syncDraftFromFields()
        let selectedTitle = sender.titleOfSelectedItem ?? AIProviderProfile.openAICompatible.displayName
        let profile = AIProviderProfile.settingsMenuProfiles.first { $0.displayName == selectedTitle }
            ?? .openAICompatible
        applyProfileTemplate(profile)
        render()
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) {
        syncDraftFromFields()
        render()
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSSearchField,
           field === modelSearchField {
            modelSearchQuery = field.stringValue
            modelTableView.reloadData()
            return
        }
        syncDraftFromFields()
        saveButton.isEnabled = canSave
        fetchModelsButton.isEnabled = isFetching == false && hasValidRequiredFields
    }

    @objc private func modelSearchChanged(_ sender: NSSearchField) {
        modelSearchQuery = sender.stringValue
        modelTableView.reloadData()
    }

    @objc private func fetchModelsPressed(_ sender: NSButton) {
        fetchModels()
    }

    private func fetchModels() {
        syncDraftFromFields()
        guard hasValidRequiredFields else {
            activeFetchRequest = nil
            completedFetchInput = nil
            isFetching = false
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.Settings.addAIProviderInvalidRequiredFields
            render()
            return
        }

        let request = FetchRequest(token: UUID(), input: currentFetchInput)
        activeFetchRequest = request
        completedFetchInput = nil
        isFetching = true
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = L10n.Settings.addAIProviderFetching
        render()

        let provider = draft.makeConfiguration(id: providerIDForMutation())
        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let loader = UncheckedAddAIProviderCatalogLoader(modelCatalogLoader)
        backgroundExecutor { [weak self] in
            let result = Result {
                try loader.value.listModelEntries(
                    for: provider,
                    apiKey: apiKey.isEmpty ? nil : apiKey
                )
            }
            self?.mainExecutor { [weak self] in
                self?.handleFetchResult(result, request: request, apiKey: apiKey)
            }
        }
    }

    private func handleFetchResult(
        _ result: Result<[AIModelCatalogEntry], Error>,
        request: FetchRequest,
        apiKey: String
    ) {
        guard activeFetchRequest == request,
              currentFetchInput == request.input
        else {
            return
        }
        activeFetchRequest = nil
        completedFetchInput = request.input
        isFetching = false
        switch result {
        case let .success(entries):
            let existingModels = draft.models
            let previousDefaultModelID = draft.defaultModelID
            var mergedModels = AIProviderModelCatalogMerger.merge(
                existing: existingModels,
                fetchedEntries: entries
            )
            if existingModels.isEmpty {
                for index in mergedModels.indices where mergedModels[index].wasReturnedByLatestCatalog {
                    mergedModels[index].isEnabled = true
                }
            }
            draft.models = mergedModels
            if let previousDefaultModelID,
               mergedModels.contains(where: {
                   $0.id == previousDefaultModelID && $0.isEnabled
               }) {
                draft.defaultModelID = previousDefaultModelID
            } else {
                draft.defaultModelID = mergedModels.first(where: \.isEnabled)?.id
            }
            statusLabel.textColor = StacioDesignSystem.theme.successColor
            statusLabel.stringValue = "\(L10n.Settings.addAIProviderFetchSucceeded) \(draft.models.count)"
        case let .failure(error):
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.Settings.addAIProviderFetchFailedPrefix
                + redactedMessage(for: error, apiKey: apiKey)
        }
        render()
    }

    @objc private func addManualModelPressed(_ sender: NSButton) {
        addManualModel(manualModelField.stringValue)
    }

    private func addManualModel(_ rawModelID: String) {
        let modelID = AppSettings.normalizedAIModelName(rawModelID)
        guard modelID.isEmpty == false else {
            return
        }
        if draft.models.contains(where: { $0.id == modelID }) == false {
            draft.models.append(
                AIProviderModelConfiguration(
                    id: modelID,
                    isEnabled: true,
                    isManual: true,
                    wasReturnedByLatestCatalog: false
                )
            )
        }
        draft.defaultModelID = draft.defaultModelID ?? modelID
        manualModelField.stringValue = ""
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = ""
        render()
    }

    @objc private func savePressed(_ sender: NSButton) {
        do {
            try saveDraft()
        } catch {
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.Settings.addAIProviderSaveFailedPrefix
                + redactedMessage(for: error, apiKey: draft.apiKey)
            render()
        }
    }

    private func saveDraft() throws {
        syncDraftFromFields()
        guard canSave else {
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = hasValidRequiredFields
                ? L10n.Settings.addAIProviderDefaultRequired
                : L10n.Settings.addAIProviderInvalidRequiredFields
            throw AIProviderSheetValidationError.invalidDraft
        }

        let id = providerIDForMutation()
        let provider = draft.makeConfiguration(id: id)
        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try mutationCoordinator.saveProvider(
            provider,
            apiKeyUpdate: apiKey.isEmpty ? .unchanged : .replace(apiKey)
        )
        statusLabel.textColor = StacioDesignSystem.theme.successColor
        statusLabel.stringValue = L10n.Settings.addAIProviderSaved
        onSaved?(id)
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        onCancel?()
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
        max(visibleModels.count, visibleModels.isEmpty ? 1 : 0)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let models = visibleModels
        guard models.isEmpty == false else {
            let message = draft.models.isEmpty
                ? L10n.Settings.addAIProviderNoModels
                : L10n.Settings.addAIProviderNoMatchingModels
            let label = NSTextField(labelWithString: message)
            label.textColor = StacioDesignSystem.theme.secondaryTextColor
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        let model = models[row]
        guard let modelIndex = draft.models.firstIndex(where: { $0.id == model.id }) else {
            return nil
        }
        switch tableColumn?.identifier.rawValue {
        case "enabled":
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(modelEnabledChanged(_:)))
            button.tag = modelIndex
            button.state = model.isEnabled ? .on : .off
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
        guard draft.models.indices.contains(sender.tag) else {
            return
        }
        draft.models[sender.tag].isEnabled = sender.state == .on
        if draft.models[sender.tag].isEnabled == false,
           draft.defaultModelID == draft.models[sender.tag].id {
            draft.defaultModelID = draft.models.first(where: \.isEnabled)?.id
        }
        render()
    }

    @objc private func defaultModelChanged(_ sender: NSButton) {
        guard draft.models.indices.contains(sender.tag) else {
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

    func setDraft(name: String, baseURL: String, apiKey: String) {
        let previousInput = currentFetchInput
        draft.displayName = name
        draft.baseURL = baseURL
        draft.apiKey = apiKey
        invalidateFetchStateIfNeeded(previousInput: previousInput)
        if isViewLoaded {
            render()
        }
    }

    func fetchModelsForTesting() {
        fetchModels()
    }

    func saveForTesting() {
        try? saveDraft()
    }

    func addManualModelForTesting(_ modelID: String) {
        addManualModel(modelID)
    }

    func setDefaultModelForTesting(_ modelID: String) {
        if let index = draft.models.firstIndex(where: { $0.id == modelID }) {
            draft.models[index].isEnabled = true
            draft.defaultModelID = modelID
        }
        render()
    }

    func setModelEnabledForTesting(_ modelID: String, isEnabled: Bool) {
        if let index = draft.models.firstIndex(where: { $0.id == modelID }) {
            draft.models[index].isEnabled = isEnabled
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
