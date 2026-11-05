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

private struct AIProviderConfigurationExportDocument: Codable {
    let format: String
    let exportedAt: Date
    let providers: [AIProviderConfiguration]
    let defaultProviderID: UUID
}

private enum AIProviderConfigurationImportError: LocalizedError {
    case invalidFormat
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "供应商配置文件格式无效。"
        case .fileTooLarge:
            return "供应商配置文件过大，无法导入。"
        }
    }
}

private enum AIProviderConfigurationFileCodec {
    static let maxImportBytes = 2 * 1024 * 1024

    static func write(
        _ document: AIProviderConfigurationExportDocument,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> AIProviderConfigurationExportDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value <= UInt64(maxImportBytes)
        else {
            throw AIProviderConfigurationImportError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maxImportBytes else {
            throw AIProviderConfigurationImportError.fileTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(AIProviderConfigurationExportDocument.self, from: data)
        guard document.format == "stacio.ai-providers.v1" else {
            throw AIProviderConfigurationImportError.invalidFormat
        }
        return document
    }
}

private enum AIProviderCredentialAvailability: Equatable {
    case loading
    case available
    case missing
    case failed

    var hasStoredAPIKey: Bool {
        self == .available
    }
}

private struct AIProviderEditDraft {
    var provider: AIProviderConfiguration
    var credentialAvailability: AIProviderCredentialAvailability

    var hasStoredAPIKey: Bool {
        get { credentialAvailability.hasStoredAPIKey }
        set { credentialAvailability = newValue ? .available : .missing }
    }
}

private struct AIProviderConnectionRequestSnapshot: Equatable {
    let provider: AIProviderConfiguration
    let modelID: String
    let apiKey: String?
}

private struct AIProviderCatalogRequestSnapshot: Equatable {
    let provider: AIProviderConfiguration
    let apiKey: String?
}

private enum AIProviderRequestMutationOutcome {
    case applied(envelope: AIProviderSettingsEnvelope, hasStoredAPIKey: Bool)
    case stale
    case failed(Error)
}

private enum AIProviderCredentialReadOutcome {
    case available(String)
    case missing
    case stale
    case failed(Error)
}

private enum AIProviderCredentialConfirmationPersistenceOutcome {
    case saved(AIProviderSettingsEnvelope)
    case stale
    case failed(Error)
}

private enum AIProviderSavePersistenceOutcome {
    case saved(AIProviderSettingsEnvelope)
    case stale(
        envelope: AIProviderSettingsEnvelope,
        credentialAvailability: AIProviderCredentialAvailability
    )
    case failed(
        error: Error,
        envelope: AIProviderSettingsEnvelope?,
        credentialAvailability: AIProviderCredentialAvailability
    )
}

private enum AIProviderManagementMutationError: LocalizedError {
    case providerChanged

    var errorDescription: String? {
        switch self {
        case .providerChanged:
            return "供应商配置已在其他位置更改，已重新加载，请确认后再保存。"
        }
    }
}

private enum AIProviderDeletePersistenceOutcome {
    case deleted(AIProviderSettingsEnvelope)
    case stale(AIProviderSettingsEnvelope)
    case failed(Error)
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

private final class UncheckedAIProviderPersistenceBox: @unchecked Sendable {
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
    private static let providerDragPasteboardType = NSPasteboard.PasteboardType("cn.stacio.ai-provider")

    var onAddProviderRequested: (() -> Void)?
    var onDeleteProviderConfirmationRequested: AIProviderDeleteConfirmationHandler?

    private let settingsStore: AIProviderSettingsStoring
    private let mutationCoordinator: AIProviderMutationCoordinating
    private let modelCatalogLoader: AIModelCatalogLoading
    private let connectionTester: AIAssistantConnectionTesting
    private let runtimeCatalog: BundledRuntimeCatalog
    private let urlOpener: StacioURLOpening
    private let backgroundExecutor: AIProviderTaskExecutor
    private let mainExecutor: AIProviderTaskExecutor
    private let persistenceExecutor: AIProviderTaskExecutor
    private let now: () -> Date
    private let credentialOriginConfirmationHandler: AIProviderCredentialOriginConfirmationHandler

    internal private(set) var currentEnvelope: AIProviderSettingsEnvelope = .defaultConfiguration
    internal private(set) var selectedProviderID = BuiltInAIProvider.stacioRulesID
    private var catalogStates: [UUID: AIProviderCatalogUIState] = [:]
    private var catalogRequestTokens: [UUID: UUID] = [:]
    private var catalogRequestSnapshots: [UUID: AIProviderCatalogRequestSnapshot] = [:]
    private var connectionStates: [UUID: AIProviderConnectionUIState] = [:]
    private var connectionRequestTokens: [UUID: UUID] = [:]
    private var connectionRequestModelIDs: [UUID: String] = [:]
    private var connectionRequestSnapshots: [UUID: AIProviderConnectionRequestSnapshot] = [:]
    private var editDrafts: [UUID: AIProviderEditDraft] = [:]
    private var settingsLoadErrorMessage: String?
    private var configurationMutationErrorMessage: String?
    private var configurationIORequestToken: UUID?
    private var persistenceRequestTokens: [UUID: UUID] = [:]
    private var persistenceMutationTokens: [UUID: UUID] = [:]
    private var pendingLocalSaveVersions: [UUID: [AIProviderConfiguration]] = [:]
    private var credentialRequestTokens: [UUID: UUID] = [:]
    private var credentialGateTokens: [UUID: UUID] = [:]
    private var isSettingsLoading = false
    private var lifecycleGeneration = 0
    private var shouldReloadOnNextAppearance = false
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
    private let exportProviderButton = NSButton()
    private let importProviderButton = NSButton()

    private let providerNameLabel = NSTextField(labelWithString: "")
    private let providerStatusLabel = NSTextField(labelWithString: "")
    private let providerActivationButton = NSButton()
    private let visitWebsiteButton = NSButton()
    private let testConnectionButton = NSButton()
    private let refreshModelsButton = NSButton()
    private let displayNameField = NSTextField()
    private let baseURLField = NSTextField()
    private let restoreOfficialURLButton = NSButton()
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
    private var apiKeyRow: NSView?
    private var manualModelRow: NSView?
    private var isAPIKeyRevealed = false

    init(
        settingsStore: AIProviderSettingsStoring,
        mutationCoordinator: AIProviderMutationCoordinating,
        modelCatalogLoader: AIModelCatalogLoading,
        connectionTester: AIAssistantConnectionTesting,
        runtimeCatalog: BundledRuntimeCatalog = .shared,
        urlOpener: StacioURLOpening? = nil,
        backgroundExecutor: @escaping AIProviderTaskExecutor = { operation in
            let box = UncheckedAIProviderTaskBox(operation)
            DispatchQueue.global(qos: .userInitiated).async {
                box.operation()
            }
        },
        persistenceExecutor: @escaping AIProviderTaskExecutor = AIProviderManagementViewController.makeDefaultPersistenceExecutor(),
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
        credentialOriginConfirmationHandler: @escaping AIProviderCredentialOriginConfirmationHandler = {
            AIProviderCredentialOriginConfirmationPresenter.confirm($0)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.mutationCoordinator = mutationCoordinator
        self.modelCatalogLoader = modelCatalogLoader
        self.connectionTester = connectionTester
        self.runtimeCatalog = runtimeCatalog
        self.urlOpener = urlOpener ?? WorkspaceURLOpener()
        self.backgroundExecutor = backgroundExecutor
        self.mainExecutor = mainExecutor
        self.persistenceExecutor = persistenceExecutor
        self.credentialOriginConfirmationHandler = credentialOriginConfirmationHandler
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

        isSettingsLoading = true
        reloadFromStoreInBackground(selecting: nil)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        concealAPIKey()
        invalidateAllRequests()
        cancelConfigurationIO()
        persistenceRequestTokens.removeAll()
        persistenceMutationTokens.removeAll()
        pendingLocalSaveVersions.removeAll()
        credentialRequestTokens.removeAll()
        credentialGateTokens.removeAll()
        lifecycleGeneration &+= 1
        shouldReloadOnNextAppearance = true
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard shouldReloadOnNextAppearance else { return }
        shouldReloadOnNextAppearance = false
        reloadFromStoreInBackground(selecting: selectedProviderID)
    }

    nonisolated private static func makeDefaultPersistenceExecutor() -> AIProviderTaskExecutor {
        let queue = DispatchQueue(
            label: "com.stacio.ai-provider-persistence",
            qos: .userInitiated
        )
        return { operation in
            let box = UncheckedAIProviderPersistenceBox(operation)
            queue.async {
                box.operation()
            }
        }
    }

    private func reloadFromStoreInBackground(selecting requestedProviderID: UUID?) {
        lifecycleGeneration &+= 1
        let token = UUID()
        let generation = lifecycleGeneration
        invalidateAllRequests()
        persistenceMutationTokens.removeAll()
        pendingLocalSaveVersions.removeAll()
        credentialRequestTokens.removeAll()
        credentialGateTokens.removeAll()
        editDrafts.removeAll()
        isSettingsLoading = true
        renderSelectedProvider()
        persistenceRequestTokens[BuiltInAIProvider.stacioRulesID] = token
        let store = settingsStore
        let mainExecutor = self.mainExecutor
        persistenceExecutor { [weak self] in
            let result = Result {
                AIProviderSettingsNormalizer.normalized(
                    try store.loadAIProviderSettings()
                )
            }
            mainExecutor { [weak self] in
                guard let self,
                      self.persistenceRequestTokens[BuiltInAIProvider.stacioRulesID] == token,
                      self.lifecycleGeneration == generation
                else { return }
                self.persistenceRequestTokens[BuiltInAIProvider.stacioRulesID] = nil
                self.isSettingsLoading = false
                switch result {
                case let .success(envelope):
                    self.applyReloadedEnvelope(envelope, selecting: requestedProviderID)
                case let .failure(error):
                    self.currentEnvelope = .defaultConfiguration
                    self.selectedProviderID = self.preferredProviderID()
                    self.settingsLoadErrorMessage = self.actionableMessage(for: error, apiKey: nil)
                    self.providerTableView.reloadData()
                    self.syncProviderTableSelection()
                    self.renderSelectedProvider()
                }
            }
        }
    }

    func reloadFromStoreAsync(selecting requestedProviderID: UUID?) {
        reloadFromStoreInBackground(selecting: requestedProviderID)
    }

    private func applyReloadedEnvelope(
        _ loaded: AIProviderSettingsEnvelope,
        selecting requestedProviderID: UUID?
    ) {
        isSettingsLoading = false
        configurationMutationErrorMessage = nil
        editDrafts.removeAll()
        catalogStates.removeAll()
        catalogRequestTokens.removeAll()
        catalogRequestSnapshots.removeAll()
        connectionStates.removeAll()
        connectionRequestTokens.removeAll()
        connectionRequestModelIDs.removeAll()
        connectionRequestSnapshots.removeAll()
        currentEnvelope = loaded
        settingsLoadErrorMessage = nil
        reconcileSelectionAfterReload(requestedProviderID)
        _ = draft(for: selectedProviderID)
        providerTableView.reloadData()
        syncProviderTableSelection()
        renderSelectedProvider()
    }

    private func applySuccessfulProviderMutationEnvelope(
        _ envelope: AIProviderSettingsEnvelope,
        providerID: UUID
    ) {
        guard let savedProvider = envelope.aiProviders.first(where: { $0.id == providerID }),
              let currentIndex = currentEnvelope.aiProviders.firstIndex(where: {
                  $0.id == providerID
              })
        else { return }
        currentEnvelope.formatVersion = envelope.formatVersion
        currentEnvelope.aiProviders[currentIndex] = savedProvider
        currentEnvelope.legacyKeyMigrationProviderID = envelope.legacyKeyMigrationProviderID
    }

    private func applySuccessfulDefaultMutationEnvelope(
        _ envelope: AIProviderSettingsEnvelope
    ) {
        currentEnvelope.formatVersion = envelope.formatVersion
        currentEnvelope.defaultAIProviderID = envelope.defaultAIProviderID
        currentEnvelope.legacyKeyMigrationProviderID = envelope.legacyKeyMigrationProviderID
    }

    private func applySuccessfulOrderMutationEnvelope(
        _ envelope: AIProviderSettingsEnvelope
    ) {
        let currentByID = Dictionary(
            uniqueKeysWithValues: currentEnvelope.aiProviders.map { ($0.id, $0) }
        )
        currentEnvelope.formatVersion = envelope.formatVersion
        currentEnvelope.aiProviders = envelope.aiProviders.map { provider in
            currentByID[provider.id] ?? provider
        }
        currentEnvelope.defaultAIProviderID = envelope.defaultAIProviderID
        currentEnvelope.legacyKeyMigrationProviderID = envelope.legacyKeyMigrationProviderID
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

    private func enqueuePersistence<T>(
        operation: @escaping () throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        let persistenceExecutor = self.persistenceExecutor
        let mainExecutor = self.mainExecutor
        persistenceExecutor {
            let result: Result<T, Error>
            do {
                result = .success(try operation())
            } catch {
                result = .failure(error)
            }
            mainExecutor {
                completion(result)
            }
        }
    }

    private func beginPersistenceMutation(for key: UUID) -> UUID {
        let token = UUID()
        persistenceMutationTokens[key] = token
        return token
    }

    private func acceptsPersistenceMutation(for key: UUID, token: UUID) -> Bool {
        persistenceMutationTokens[key] == token
    }

    private func finishPersistenceMutation(for key: UUID, token: UUID) {
        guard persistenceMutationTokens[key] == token else { return }
        persistenceMutationTokens[key] = nil
    }

    private func appendPendingLocalVersion(_ provider: AIProviderConfiguration) {
        if pendingLocalSaveVersions[provider.id]?.last != provider {
            pendingLocalSaveVersions[provider.id, default: []].append(provider)
        }
    }

    private func removePendingLocalVersion(_ provider: AIProviderConfiguration) {
        guard var versions = pendingLocalSaveVersions[provider.id],
              let index = versions.firstIndex(of: provider)
        else { return }
        versions.remove(at: index)
        pendingLocalSaveVersions[provider.id] = versions.isEmpty ? nil : versions
    }

    private func invalidatePersistenceState() {
        lifecycleGeneration &+= 1
        // A settings reload uses the same persistence executor as mutations.
        // Invalidate its request token as well, otherwise an initial-load
        // completion that arrives after an import can replace the imported
        // envelope with the stale snapshot it captured before the import.
        persistenceRequestTokens.removeAll()
        persistenceMutationTokens.removeAll()
        pendingLocalSaveVersions.removeAll()
        credentialRequestTokens.removeAll()
        credentialGateTokens.removeAll()
    }

    private static func locallyEditedValue<Value: Equatable>(
        base: Value,
        draft: Value,
        latest: Value
    ) -> Value {
        draft == base ? latest : draft
    }

    private static func rebasedCapabilities(
        base: AIModelCapabilityConfiguration,
        draft: AIModelCapabilityConfiguration,
        latest: AIModelCapabilityConfiguration
    ) -> AIModelCapabilityConfiguration {
        var result = latest
        result.contextWindowTokens = locallyEditedValue(
            base: base.contextWindowTokens,
            draft: draft.contextWindowTokens,
            latest: latest.contextWindowTokens
        )
        result.contextCharacterLimit = locallyEditedValue(
            base: base.contextCharacterLimit,
            draft: draft.contextCharacterLimit,
            latest: latest.contextCharacterLimit
        )
        result.contextCharacterLimitSource = locallyEditedValue(
            base: base.contextCharacterLimitSource,
            draft: draft.contextCharacterLimitSource,
            latest: latest.contextCharacterLimitSource
        )
        result.supportedReasoningEfforts = locallyEditedValue(
            base: base.supportedReasoningEfforts,
            draft: draft.supportedReasoningEfforts,
            latest: latest.supportedReasoningEfforts
        )
        result.supportedReasoningEffortsSource = locallyEditedValue(
            base: base.supportedReasoningEffortsSource,
            draft: draft.supportedReasoningEffortsSource,
            latest: latest.supportedReasoningEffortsSource
        )
        result.reasoningEffort = locallyEditedValue(
            base: base.reasoningEffort,
            draft: draft.reasoningEffort,
            latest: latest.reasoningEffort
        )
        result.reasoningEffortSource = locallyEditedValue(
            base: base.reasoningEffortSource,
            draft: draft.reasoningEffortSource,
            latest: latest.reasoningEffortSource
        )
        return result.normalized()
    }

    private static func rebasedModel(
        base: AIProviderModelConfiguration,
        draft: AIProviderModelConfiguration,
        latest: AIProviderModelConfiguration
    ) -> AIProviderModelConfiguration {
        AIProviderModelConfiguration(
            id: draft.id,
            isEnabled: locallyEditedValue(
                base: base.isEnabled,
                draft: draft.isEnabled,
                latest: latest.isEnabled
            ),
            isManual: locallyEditedValue(
                base: base.isManual,
                draft: draft.isManual,
                latest: latest.isManual
            ),
            wasReturnedByLatestCatalog: locallyEditedValue(
                base: base.wasReturnedByLatestCatalog,
                draft: draft.wasReturnedByLatestCatalog,
                latest: latest.wasReturnedByLatestCatalog
            ),
            lastVerifiedAt: locallyEditedValue(
                base: base.lastVerifiedAt,
                draft: draft.lastVerifiedAt,
                latest: latest.lastVerifiedAt
            ),
            capabilities: rebasedCapabilities(
                base: base.capabilities,
                draft: draft.capabilities,
                latest: latest.capabilities
            )
        )
    }

    private static func rebasedModels(
        base: [AIProviderModelConfiguration],
        draft: [AIProviderModelConfiguration],
        latest: [AIProviderModelConfiguration]
    ) -> [AIProviderModelConfiguration] {
        let baseByID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let draftByID = Dictionary(uniqueKeysWithValues: draft.map { ($0.id, $0) })
        let removedIDs = Set(baseByID.keys).subtracting(draftByID.keys)
        var result = latest.filter { removedIDs.contains($0.id) == false }

        for draftModel in draft {
            guard let baseModel = baseByID[draftModel.id] else {
                if let index = result.firstIndex(where: { $0.id == draftModel.id }) {
                    result[index] = draftModel
                } else {
                    result.append(draftModel)
                }
                continue
            }
            guard draftModel != baseModel else { continue }
            if let index = result.firstIndex(where: { $0.id == draftModel.id }) {
                result[index] = rebasedModel(
                    base: baseModel,
                    draft: draftModel,
                    latest: result[index]
                )
            } else {
                result.append(draftModel)
            }
        }
        return result
    }

    private static func modelsRepresentGlobalVerificationInvalidation(
        base: [AIProviderModelConfiguration],
        draft: [AIProviderModelConfiguration]
    ) -> Bool {
        guard base.count == draft.count else { return false }
        let draftByID = Dictionary(uniqueKeysWithValues: draft.map { ($0.id, $0) })
        return base.allSatisfy { baseModel in
            guard let draftModel = draftByID[baseModel.id],
                  draftModel.id == baseModel.id,
                  draftModel.isManual == baseModel.isManual,
                  draftModel.isEnabled == baseModel.isEnabled,
                  draftModel.capabilities == baseModel.capabilities,
                  draftModel.lastVerifiedAt == nil
            else { return false }
            if baseModel.isManual {
                return draftModel.wasReturnedByLatestCatalog == baseModel.wasReturnedByLatestCatalog
            }
            return draftModel.wasReturnedByLatestCatalog == false
        }
    }

    private static func invalidatedModelsPreservingLatest(
        _ latest: [AIProviderModelConfiguration]
    ) -> [AIProviderModelConfiguration] {
        latest.map { model in
            var updated = model
            updated.lastVerifiedAt = nil
            if updated.isManual == false {
                updated.wasReturnedByLatestCatalog = false
            }
            return updated
        }
    }

    private static func rebasedProvider(
        base: AIProviderConfiguration,
        draft: AIProviderConfiguration,
        latest: AIProviderConfiguration,
        impact: AIProviderMutationImpact
    ) -> AIProviderConfiguration {
        var result = latest
        result.displayName = locallyEditedValue(
            base: base.displayName,
            draft: draft.displayName,
            latest: latest.displayName
        )
        result.baseURL = locallyEditedValue(
            base: base.baseURL,
            draft: draft.baseURL,
            latest: latest.baseURL
        )
        if draft.models == base.models {
            result.models = latest.models
        } else if impact == .catalogAndConnection,
                  modelsRepresentGlobalVerificationInvalidation(
                      base: base.models,
                      draft: draft.models
                  ) {
            result.models = invalidatedModelsPreservingLatest(latest.models)
        } else {
            result.models = rebasedModels(
                base: base.models,
                draft: draft.models,
                latest: latest.models
            )
        }
        result.defaultModelID = locallyEditedValue(
            base: base.defaultModelID,
            draft: draft.defaultModelID,
            latest: latest.defaultModelID
        )
        result.compatibilityProtocol = locallyEditedValue(
            base: base.compatibilityProtocol,
            draft: draft.compatibilityProtocol,
            latest: latest.compatibilityProtocol
        )
        result.maxRetryCount = locallyEditedValue(
            base: base.maxRetryCount,
            draft: draft.maxRetryCount,
            latest: latest.maxRetryCount
        )
        result.requestTimeoutSeconds = locallyEditedValue(
            base: base.requestTimeoutSeconds,
            draft: draft.requestTimeoutSeconds,
            latest: latest.requestTimeoutSeconds
        )
        result.userAgent = locallyEditedValue(
            base: base.userAgent,
            draft: draft.userAgent,
            latest: latest.userAgent
        )
        result.isEnabled = locallyEditedValue(
            base: base.isEnabled,
            draft: draft.isEnabled,
            latest: latest.isEnabled
        )
        result.lastVerifiedAt = locallyEditedValue(
            base: base.lastVerifiedAt,
            draft: draft.lastVerifiedAt,
            latest: latest.lastVerifiedAt
        )
        result.lastModelSyncAt = locallyEditedValue(
            base: base.lastModelSyncAt,
            draft: draft.lastModelSyncAt,
            latest: latest.lastModelSyncAt
        )
        result.catalogRevisionAtCreation = locallyEditedValue(
            base: base.catalogRevisionAtCreation,
            draft: draft.catalogRevisionAtCreation,
            latest: latest.catalogRevisionAtCreation
        )
        result.baseURLSource = locallyEditedValue(
            base: base.baseURLSource,
            draft: draft.baseURLSource,
            latest: latest.baseURLSource
        )
        result.wasBaseURLUserEdited = locallyEditedValue(
            base: base.wasBaseURLUserEdited,
            draft: draft.wasBaseURLUserEdited,
            latest: latest.wasBaseURLUserEdited
        )
        result.confirmedCredentialOrigin = locallyEditedValue(
            base: base.confirmedCredentialOrigin,
            draft: draft.confirmedCredentialOrigin,
            latest: latest.confirmedCredentialOrigin
        )
        return result
    }

    private func normalizedCredential(_ candidate: String?) -> String? {
        candidate.flatMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func loadCredentialAvailability(
        for providerID: UUID,
        expectedProvider: AIProviderConfiguration
    ) {
        guard requiresCredential(for: expectedProvider) else {
            if var draft = editDrafts[providerID], draft.provider == expectedProvider {
                draft.credentialAvailability = .missing
                editDrafts[providerID] = draft
            }
            return
        }
        let token = UUID()
        let generation = lifecycleGeneration
        credentialRequestTokens[providerID] = token
        enqueuePersistence(operation: { [mutationCoordinator] in
            try mutationCoordinator.readAPIKey(for: providerID)
        }, completion: { [weak self] result in
            guard let self,
                  self.lifecycleGeneration == generation,
                  self.credentialRequestTokens[providerID] == token,
                  var draft = self.editDrafts[providerID]
            else { return }
            self.credentialRequestTokens[providerID] = nil
            switch result {
            case let .success(apiKey):
                draft.credentialAvailability = self.normalizedCredential(apiKey) == nil
                    ? .missing
                    : .available
            case let .failure(error):
                draft.credentialAvailability = .failed
                self.connectionStates[providerID] = .failed(
                    self.actionableMessage(for: error, apiKey: nil)
                )
            }
            self.editDrafts[providerID] = draft
            if self.selectedProviderID == providerID {
                self.renderSelectedProvider()
            } else {
                self.providerTableView.reloadData()
            }
        })
    }

    private func readCredential(
        for provider: AIProviderConfiguration,
        completion: @escaping (AIProviderCredentialReadOutcome) -> Void
    ) {
        guard requiresCredential(for: provider) else {
            completion(.missing)
            return
        }
        let providerID = provider.id
        let token = UUID()
        let generation = lifecycleGeneration
        credentialRequestTokens[providerID] = token
        enqueuePersistence(operation: { [mutationCoordinator] in
            try mutationCoordinator.readAPIKey(for: providerID)
        }, completion: { [weak self] result in
            guard let self,
                  self.lifecycleGeneration == generation,
                  self.credentialRequestTokens[providerID] == token
            else { return }
            self.credentialRequestTokens[providerID] = nil
            guard self.providerForDisplay(id: providerID) == provider else {
                completion(.stale)
                return
            }
            switch result {
            case let .success(candidate):
                guard let apiKey = self.normalizedCredential(candidate) else {
                    if var draft = self.editDrafts[providerID] {
                        draft.credentialAvailability = .missing
                        self.editDrafts[providerID] = draft
                    }
                    completion(.missing)
                    return
                }
                if var draft = self.editDrafts[providerID] {
                    draft.credentialAvailability = .available
                    self.editDrafts[providerID] = draft
                }
                completion(.available(apiKey))
            case let .failure(error):
                if var draft = self.editDrafts[providerID] {
                    draft.credentialAvailability = .failed
                    self.editDrafts[providerID] = draft
                }
                completion(.failed(error))
            }
        })
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

    var providerActivationButtonTitleForTesting: String {
        providerActivationButton.title
    }

    var providerActivationButtonEnabledForTesting: Bool {
        providerActivationButton.isEnabled
    }

    func toggleProviderActivationForTesting() {
        toggleSelectedProviderActivation()
    }

    var restoreOfficialURLButtonVisibleForTesting: Bool {
        restoreOfficialURLButton.isHidden == false
    }

    var selectedProviderWebsiteURLForTesting: URL? {
        guard let provider = providerForDisplay(id: selectedProviderID) else { return nil }
        return primaryWebsiteAction(for: provider)?.descriptor?.url
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

    func restoreOfficialURLForTesting() {
        restoreOfficialURL()
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

    var isSettingsLoadingForTesting: Bool {
        isSettingsLoading
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

    func moveProviderForTesting(from sourceRow: Int, to destinationRow: Int) -> Bool {
        moveProvider(from: sourceRow, to: destinationRow)
    }

    func exportConfigurationForTesting(to url: URL) throws {
        try exportConfiguration(to: url)
    }

    func importConfigurationForTesting(from url: URL) throws {
        let document = try AIProviderConfigurationFileCodec.read(from: url)
        invalidateAllRequests()
        invalidatePersistenceState()
        let envelope = try Self.applyImportedConfiguration(
            document,
            settingsStore: settingsStore,
            mutationCoordinator: mutationCoordinator
        )
        applyImportedEnvelope(envelope)
    }

    func exportConfigurationInBackgroundForTesting(to url: URL) {
        exportConfigurationInBackground(to: url)
    }

    func importConfigurationInBackgroundForTesting(from url: URL) {
        importConfigurationInBackground(from: url)
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
        let query = normalizedSearchQuery(providerSearchQuery)
        guard query.isEmpty == false else { return providerIDs }
        return providerIDs.filter { id in
            guard let provider = providerForDisplay(id: id) else { return false }
            var searchableValues = [
                displayName(for: provider),
                displayedBaseURL(for: provider),
                provider.profile.displayName
            ]
            if let descriptor = catalogDescriptor(for: provider) {
                searchableValues.append(descriptor.displayName)
                searchableValues.append(contentsOf: descriptor.aliases)
            }
            return searchableValues.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
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
        providerTableView.registerForDraggedTypes([Self.providerDragPasteboardType])
        providerTableView.setDraggingSourceOperationMask(.move, forLocal: true)
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
        configureIconButton(
            exportProviderButton,
            symbolName: "square.and.arrow.up",
            toolTip: "导出供应商配置",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.export",
            action: #selector(exportProviderPressed(_:))
        )
        configureIconButton(
            importProviderButton,
            symbolName: "square.and.arrow.down",
            toolTip: "导入供应商配置",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.import",
            action: #selector(importProviderPressed(_:))
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
            providerActivationButton,
            title: "验证并启用",
            symbolName: "checkmark.shield",
            toolTip: "验证默认模型并启用当前供应商",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.activation",
            action: #selector(providerActivationPressed(_:))
        )

        configureCommandButton(
            visitWebsiteButton,
            title: "访问官网",
            symbolName: "arrow.up.right.square",
            toolTip: "在浏览器中访问当前供应商官网",
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
        configureIconButton(
            restoreOfficialURLButton,
            symbolName: "arrow.counterclockwise",
            toolTip: "恢复 Catalog 建议的 Base URL",
            accessibilityIdentifier: "Stacio.Settings.aiProviders.restoreOfficialURL",
            action: #selector(restoreOfficialURLPressed(_:))
        )
        restoreOfficialURLButton.isHidden = true
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

        let toolbar = NSStackView(views: [
            addProviderButton,
            removeProviderButton,
            moreProviderButton,
            exportProviderButton,
            importProviderButton,
            NSView()
        ])
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

        let actionStack = NSStackView(views: [
            providerActivationButton,
            visitWebsiteButton,
            testConnectionButton,
            refreshModelsButton
        ])
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
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.compatibilityProtocol",
            stabilizesPopupLayout: true
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
        manualModelRow = manualAddRow

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
        let baseURLControls = NSStackView(views: [baseURLField, restoreOfficialURLButton])
        baseURLControls.orientation = .horizontal
        baseURLControls.alignment = .centerY
        baseURLControls.spacing = 6
        baseURLControls.detachesHiddenViews = true
        baseURLControls.translatesAutoresizingMaskIntoConstraints = false
        baseURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        restoreOfficialURLButton.setContentHuggingPriority(.required, for: .horizontal)
        let baseURLRow = makeFormRow(
            label: "Base URL",
            control: baseURLControls,
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.baseURL"
        )
        let apiKeyRow = makeFormRow(
            label: "API Key",
            control: apiKeyControls,
            accessibilityIdentifier: "Stacio.Settings.aiProviders.form.apiKey"
        )
        self.apiKeyRow = apiKeyRow
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
        accessibilityIdentifier: String? = nil,
        stabilizesPopupLayout: Bool = false
    ) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let arrangedControl: NSView
        if stabilizesPopupLayout, let popup = control as? NSPopUpButton {
            // AppKit 14 applies a five-point alignment inset to popup buttons on some runners.
            // Keep the form column stable by measuring a zero-inset container instead.
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            popup.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(popup)
            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                popup.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                popup.topAnchor.constraint(equalTo: container.topAnchor),
                popup.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            arrangedControl = container
        } else {
            control.translatesAutoresizingMaskIntoConstraints = false
            arrangedControl = control
        }
        arrangedControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        arrangedControl.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [label, arrangedControl])
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

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard tableView === providerTableView,
              normalizedSearchQuery(providerSearchQuery).isEmpty,
              visibleProviderIDs.indices.contains(row)
        else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setString(visibleProviderIDs[row].uuidString, forType: Self.providerDragPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard tableView === providerTableView,
              normalizedSearchQuery(providerSearchQuery).isEmpty,
              info.draggingSource as? NSTableView === providerTableView,
              let rawValue = info.draggingPasteboard.string(forType: Self.providerDragPasteboardType),
              let sourceID = UUID(uuidString: rawValue),
              visibleProviderIDs.contains(sourceID),
              operation == .above
        else {
            return []
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard tableView === providerTableView,
              dropOperation == .above,
              let rawValue = info.draggingPasteboard.string(forType: Self.providerDragPasteboardType),
              let sourceID = UUID(uuidString: rawValue),
              let sourceRow = visibleProviderIDs.firstIndex(of: sourceID)
        else {
            return false
        }
        var destinationRow = max(0, min(row, visibleProviderIDs.count))
        if sourceRow < destinationRow {
            destinationRow -= 1
        }
        return moveProvider(from: sourceRow, to: destinationRow)
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
            let manualModelNeedsVerification = model.isManual && model.lastVerifiedAt == nil
            let catalogModelUnavailable = model.isManual == false
                && model.wasReturnedByLatestCatalog == false
            checkbox.isEnabled = isReadOnly == false
                && manualModelNeedsVerification == false
                && catalogModelUnavailable == false
            checkbox.toolTip = manualModelNeedsVerification
                ? "请先选择该模型并测试连接"
                : catalogModelUnavailable
                ? "上游目录已移除，请重新获取模型"
                : nil
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
            let manualModelNeedsVerification = model.isManual && model.lastVerifiedAt == nil
            let catalogModelUnavailable = model.isManual == false
                && model.wasReturnedByLatestCatalog == false
            button.isEnabled = isReadOnly == false
                && manualModelNeedsVerification == false
                && catalogModelUnavailable == false
            if manualModelNeedsVerification {
                button.toolTip = "请先选择该模型并测试连接"
            } else if catalogModelUnavailable {
                button.toolTip = "上游目录已移除，请重新获取模型"
            }
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
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
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

    @objc private func providerActivationPressed(_ sender: NSButton) {
        toggleSelectedProviderActivation()
    }

    @objc private func exportProviderPressed(_ sender: NSButton) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "stacio-ai-providers.json"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.exportConfigurationInBackground(to: url)
        }
    }

    @objc private func importProviderPressed(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.importConfigurationInBackground(from: url)
        }
    }

    private func exportConfiguration(to url: URL) throws {
        try AIProviderConfigurationFileCodec.write(exportConfigurationDocument(), to: url)
    }

    private func exportConfigurationDocument() -> AIProviderConfigurationExportDocument {
        let portableProviders = currentEnvelope.aiProviders
            .filter { $0.id != BuiltInAIProvider.stacioRulesID }
            .map { provider -> AIProviderConfiguration in
                var portable = provider
                portable.confirmedCredentialOrigin = nil
                return portable
            }
        return AIProviderConfigurationExportDocument(
            format: "stacio.ai-providers.v1",
            exportedAt: now(),
            providers: portableProviders,
            defaultProviderID: currentEnvelope.defaultAIProviderID
        )
    }

    nonisolated private static func applyImportedConfiguration(
        _ document: AIProviderConfigurationExportDocument,
        settingsStore: AIProviderSettingsStoring,
        mutationCoordinator: AIProviderMutationCoordinating
    ) throws -> AIProviderSettingsEnvelope {
        try AIProviderConfigurationCoordinator.withSharedTransaction {
            var merged = try settingsStore.loadAIProviderSettings()
            var credentialsToRemove: Set<UUID> = []
            for importedProvider in document.providers
                where importedProvider.id != BuiltInAIProvider.stacioRulesID {
                var provider = importedProvider
                clearVerificationAndCatalogTimestampsForImport(in: &provider)
                provider.confirmedCredentialOrigin = nil
                // Imported documents never carry a credential generation. Even
                // when an ID happens to match a local record, retaining that
                // machine's key would silently activate foreign configuration.
                credentialsToRemove.insert(provider.id)
                if merged.legacyKeyMigrationProviderID == provider.id {
                    merged.legacyKeyMigrationProviderID = nil
                }
                if let index = merged.aiProviders.firstIndex(where: { $0.id == provider.id }) {
                    merged.aiProviders[index] = provider
                } else {
                    merged.aiProviders.append(provider)
                }
            }
            if merged.aiProviders.contains(where: { $0.id == document.defaultProviderID }) {
                merged.defaultAIProviderID = document.defaultProviderID
            }
            return try mutationCoordinator.applyConfiguration(
                AIProviderSettingsNormalizer.normalized(merged),
                removingAPIKeys: credentialsToRemove,
                deletingProviderIDs: []
            )
        }
    }

    private func applyImportedEnvelope(_ envelope: AIProviderSettingsEnvelope) {
        isSettingsLoading = false
        currentEnvelope = envelope
        settingsLoadErrorMessage = nil
        configurationMutationErrorMessage = nil
        editDrafts.removeAll()
        selectedProviderID = providerExists(selectedProviderID) ? selectedProviderID : preferredProviderID()
        _ = draft(for: selectedProviderID)
        providerTableView.reloadData()
        syncProviderTableSelection()
        renderSelectedProvider()
    }

    private func exportConfigurationInBackground(to url: URL) {
        guard configurationIORequestToken == nil else { return }
        let token = beginConfigurationIO()
        let document = exportConfigurationDocument()
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result {
                try AIProviderConfigurationFileCodec.write(document, to: url)
            }
            mainExecutor {
                guard let self, self.configurationIORequestToken == token else { return }
                self.finishConfigurationIO(token: token)
                if case let .failure(error) = result {
                    self.configurationMutationErrorMessage = self.actionableMessage(
                        for: error,
                        apiKey: nil
                    )
                    self.renderSelectedProvider()
                }
            }
        }
    }

    private func importConfigurationInBackground(from url: URL) {
        guard configurationIORequestToken == nil else { return }
        let token = beginConfigurationIO()
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result {
                try AIProviderConfigurationFileCodec.read(from: url)
            }
            mainExecutor {
                guard let self, self.configurationIORequestToken == token else { return }
                do {
                    let document = try result.get()
                    self.invalidateAllRequests()
                    self.invalidatePersistenceState()
                    self.enqueuePersistence(operation: { [settingsStore = self.settingsStore, mutationCoordinator = self.mutationCoordinator] in
                        try Self.applyImportedConfiguration(
                            document,
                            settingsStore: settingsStore,
                            mutationCoordinator: mutationCoordinator
                        )
                    }, completion: { [weak self] persistenceResult in
                        guard let self, self.configurationIORequestToken == token else { return }
                        self.finishConfigurationIO(token: token)
                        switch persistenceResult {
                        case let .success(envelope):
                            self.applyImportedEnvelope(envelope)
                        case let .failure(error):
                            self.configurationMutationErrorMessage = self.actionableMessage(
                                for: error,
                                apiKey: nil
                            )
                            self.renderSelectedProvider()
                        }
                    })
                } catch {
                    self.finishConfigurationIO(token: token)
                    self.configurationMutationErrorMessage = self.actionableMessage(
                        for: error,
                        apiKey: nil
                    )
                    self.renderSelectedProvider()
                }
            }
        }
    }

    private func beginConfigurationIO() -> UUID {
        let token = UUID()
        configurationIORequestToken = token
        exportProviderButton.isEnabled = false
        importProviderButton.isEnabled = false
        return token
    }

    private func finishConfigurationIO(token: UUID) {
        guard configurationIORequestToken == token else { return }
        configurationIORequestToken = nil
        exportProviderButton.isEnabled = true
        importProviderButton.isEnabled = true
    }

    private func cancelConfigurationIO() {
        configurationIORequestToken = nil
        exportProviderButton.isEnabled = true
        importProviderButton.isEnabled = true
    }

    private func moveProvider(from sourceRow: Int, to destinationRow: Int) -> Bool {
        guard normalizedSearchQuery(providerSearchQuery).isEmpty,
              visibleProviderIDs.indices.contains(sourceRow),
              destinationRow >= 0,
              destinationRow <= visibleProviderIDs.count,
              sourceRow != destinationRow
        else {
            return false
        }
        var orderedIDs = visibleProviderIDs
        let movedID = orderedIDs.remove(at: sourceRow)
        let target = min(destinationRow, orderedIDs.count)
        guard target != sourceRow else { return false }
        orderedIDs.insert(movedID, at: target)

        invalidateAllRequests()
        let token = beginPersistenceMutation(for: BuiltInAIProvider.stacioRulesID)
        let requestedOrder = orderedIDs
        enqueuePersistence(operation: { [settingsStore, mutationCoordinator] in
            let latest = AIProviderSettingsNormalizer.normalized(
                try settingsStore.loadAIProviderSettings()
            )
            let latestIDs = latest.aiProviders
                .filter { $0.id != BuiltInAIProvider.stacioRulesID }
                .map(\.id)
            let requested = requestedOrder.filter { latestIDs.contains($0) }
            var latestOrder = requested
            latestOrder.append(contentsOf: latestIDs.filter { latestOrder.contains($0) == false })
            var envelope = latest
            envelope.aiProviders = latestOrder.compactMap { id in
                latest.aiProviders.first(where: { $0.id == id })
            }
            envelope.aiProviders.append(contentsOf: latest.aiProviders.filter {
                $0.id == BuiltInAIProvider.stacioRulesID || latestOrder.contains($0.id) == false
            })
            return try mutationCoordinator.applyConfiguration(
                AIProviderSettingsNormalizer.normalized(envelope),
                removingAPIKeys: [],
                deletingProviderIDs: []
            )
        }, completion: { [weak self] result in
            guard let self, self.acceptsPersistenceMutation(
                for: BuiltInAIProvider.stacioRulesID,
                token: token
            ) else { return }
            self.finishPersistenceMutation(for: BuiltInAIProvider.stacioRulesID, token: token)
            switch result {
            case let .success(envelope):
                self.applySuccessfulOrderMutationEnvelope(envelope)
                self.editDrafts.removeAll()
                _ = self.draft(for: self.selectedProviderID)
                self.providerTableView.reloadData()
                self.syncProviderTableSelection()
                self.renderSelectedProvider()
            case let .failure(error):
                self.configurationMutationErrorMessage = self.actionableMessage(for: error, apiKey: nil)
                self.renderSelectedProvider()
            }
        })
        return true
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

    @objc private func restoreOfficialURLPressed(_ sender: NSButton) {
        restoreOfficialURL()
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
        guard let provider = providerForDisplay(id: selectedProviderID),
              let url = primaryWebsiteAction(for: provider)?.descriptor?.url
        else { return }
        urlOpener.open(url)
    }

    private func restoreOfficialURL() {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID),
              let descriptor = catalogDescriptor(for: draft.provider),
              let suggestedBaseURL = descriptor.suggestedBaseURL,
              draft.provider.baseURL != suggestedBaseURL
        else {
            renderSelectedProvider()
            return
        }
        draft.provider.restoreCatalogBaseURL(
            suggestedBaseURL,
            catalogRevision: descriptor.revision
        )
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .catalogAndConnection)
    }

    private func commitDisplayName(_ rawDisplayName: String) {
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
        draft.provider.applyUserBaseURL(baseURL)
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .catalogAndConnection)
    }

    private func commitAPIKey(
        _ rawAPIKey: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            completion?(false)
            return
        }
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.isEmpty == false, apiKey != Self.maskedAPIKeyPlaceholder else {
            renderSelectedProvider()
            completion?(draft.hasStoredAPIKey)
            return
        }
        draft.provider.invalidateVerificationForEndpointChange()
        draft.hasStoredAPIKey = true
        save(
            draft: draft,
            apiKeyUpdate: .replace(apiKey),
            impact: .catalogAndConnection
        ) { result in
            if case .success = result {
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }

    private func pendingAPIKeyInput() -> String? {
        let value = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false, value != Self.maskedAPIKeyPlaceholder else {
            return nil
        }
        return value
    }

    private func persistPendingAPIKeyIfNeeded(
        completion: @escaping (Bool) -> Void
    ) {
        guard let apiKey = pendingAPIKeyInput() else {
            completion(editDrafts[selectedProviderID]?.credentialAvailability != .loading)
            return
        }
        commitAPIKey(apiKey, completion: completion)
    }

    private func toggleAPIKeyVisibility() {
        if isAPIKeyRevealed {
            concealAPIKey()
            return
        }

        let providerID = selectedProviderID
        persistPendingAPIKeyIfNeeded { [weak self] persisted in
            guard let self, persisted, self.selectedProviderID == providerID,
                  let provider = self.providerForDisplay(id: providerID)
            else { return }
            self.readCredential(for: provider) { [weak self] outcome in
                guard let self, self.selectedProviderID == providerID else { return }
                switch outcome {
                case let .available(apiKey):
                    self.revealedAPIKeyField.stringValue = apiKey
                    self.apiKeyField.isHidden = true
                    self.revealedAPIKeyField.isHidden = false
                    self.isAPIKeyRevealed = true
                    self.updateAPIKeyVisibilityButtonAppearance()
                case .missing, .stale:
                    self.updateAPIKeyActionAvailability(editable: true)
                case let .failed(error):
                    self.configurationMutationErrorMessage = self.actionableMessage(
                        for: error,
                        apiKey: nil
                    )
                    self.renderSelectedProvider()
                }
            }
        }
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
        let providerAllowsCredential = providerForDisplay(id: selectedProviderID).map {
            catalogDescriptor(for: $0)?.authenticationKind != CatalogAuthenticationKind.none
        } ?? false
        let hasStoredAPIKey = editDrafts[selectedProviderID]?.hasStoredAPIKey ?? false
        let hasPendingAPIKey = pendingAPIKeyInput() != nil
        toggleAPIKeyVisibilityButton.isEnabled = editable && providerAllowsCredential
            && (hasStoredAPIKey || hasPendingAPIKey || isAPIKeyRevealed)
        removeAPIKeyButton.isEnabled = editable && providerAllowsCredential && hasStoredAPIKey
    }

    private func removeAPIKey() {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }
        draft.provider.invalidateVerificationForEndpointChange()
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
        if enabled,
           draft.provider.models[index].isManual == false,
           draft.provider.models[index].wasReturnedByLatestCatalog == false {
            configurationMutationErrorMessage = "该模型已不在上游目录中，请重新获取模型。"
            renderSelectedProvider()
            return
        }
        if enabled,
           draft.provider.models[index].isManual,
           draft.provider.models[index].lastVerifiedAt == nil {
            configurationMutationErrorMessage = "手动模型必须先测试连接，测试通过后才能启用。"
            renderSelectedProvider()
            return
        }
        draft.provider.models[index].isEnabled = enabled
        if enabled, draft.provider.defaultModelID == nil {
            draft.provider.defaultModelID = modelID
        }
        if enabled == false, draft.provider.defaultModelID == modelID {
            // Clearing the default is intentional. Never silently choose a
            // different model when the user disables the current default.
            draft.provider.defaultModelID = nil
            draft.provider.isEnabled = false
        }
        draft.provider.isEnabled = false
        draft.provider.lastVerifiedAt = nil
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .connection)
    }

    private func toggleSelectedProviderActivation() {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID)
        else {
            return
        }

        if draft.provider.isEnabled {
            draft.provider.isEnabled = false
            save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
            return
        }

        if draft.provider.lastVerifiedAt != nil,
           draft.provider.defaultModelID != nil {
            draft.provider.isEnabled = true
            save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
            return
        }

        testSelectedProviderConnection()
    }

    private func setDefaultModel(_ modelID: String) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID),
              let index = draft.provider.models.firstIndex(where: { $0.id == modelID })
        else {
            return
        }
        if draft.provider.models[index].isManual == false,
           draft.provider.models[index].wasReturnedByLatestCatalog == false {
            configurationMutationErrorMessage = "该模型已不在上游目录中，请重新获取模型。"
            renderSelectedProvider()
            return
        }
        if draft.provider.models[index].isManual,
           draft.provider.models[index].lastVerifiedAt == nil {
            configurationMutationErrorMessage = "手动模型必须先测试连接，测试通过后才能设为默认。"
            renderSelectedProvider()
            return
        }
        draft.provider.models[index].isEnabled = true
        draft.provider.defaultModelID = modelID
        draft.provider.isEnabled = false
        draft.provider.lastVerifiedAt = nil
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .connection)
    }

    private func addManualModel(_ rawModelID: String) {
        guard selectedProviderID != BuiltInAIProvider.stacioRulesID,
              var draft = draft(for: selectedProviderID),
              let descriptor = catalogDescriptor(for: draft.provider),
              descriptor.allowsManualModelIDs
        else {
            configurationMutationErrorMessage = "当前供应商有模型目录，不能手动注入模型 ID。"
            renderSelectedProvider()
            return
        }
        let modelID = AppSettings.normalizedAIModelName(rawModelID)
        guard modelID.isEmpty == false else { return }
        if let index = draft.provider.models.firstIndex(where: { $0.id == modelID }) {
            selectedModelID = modelID
            if draft.provider.models[index].isManual == false {
                configurationMutationErrorMessage = "该模型来自上游目录，不能作为手动模型重复添加。"
                renderSelectedProvider()
                return
            }
        } else {
            draft.provider.models.append(
                AIProviderModelConfiguration(
                    id: modelID,
                    isEnabled: false,
                    isManual: true,
                    wasReturnedByLatestCatalog: false,
                    lastVerifiedAt: nil
                )
            )
        }
        selectedModelID = modelID
        manualModelField.stringValue = ""
        save(draft: draft, apiKeyUpdate: .unchanged, impact: .none)
    }

    private func setSelectedProviderAsDefault() {
        let id = selectedProviderID
        guard providerExists(id) else { return }
        configurationMutationErrorMessage = nil
        let mutationKey = BuiltInAIProvider.stacioRulesID
        let token = beginPersistenceMutation(for: mutationKey)
        enqueuePersistence(operation: { [mutationCoordinator] in
            try mutationCoordinator.setDefaultProvider(id: id)
        }, completion: { [weak self] result in
            guard let self, self.acceptsPersistenceMutation(
                for: mutationKey,
                token: token
            ) else { return }
            self.finishPersistenceMutation(for: mutationKey, token: token)
            switch result {
            case let .success(envelope):
                self.applySuccessfulDefaultMutationEnvelope(envelope)
                self.providerTableView.reloadData()
                self.syncProviderTableSelection()
                self.renderSelectedProvider()
            case let .failure(error):
                self.configurationMutationErrorMessage = self.actionableMessage(for: error, apiKey: nil)
                self.renderSelectedProvider()
            }
        })
    }

    private func performDeleteSelectedProvider() {
        performDeleteProvider(id: selectedProviderID)
    }

    private func performDeleteProvider(id deletedID: UUID) {
        guard deletedID != BuiltInAIProvider.stacioRulesID else {
            return
        }
        let deletedProviderWasSelected = selectedProviderID == deletedID
        guard let deletedProviderSnapshot = persistedProvider(id: deletedID) else { return }
        let acceptedProviderVersions = [deletedProviderSnapshot]
            + (pendingLocalSaveVersions[deletedID] ?? [])
        configurationMutationErrorMessage = nil
        invalidateRequests(for: deletedID, catalog: true, connection: true)
        // Delete supersedes this window's queued edits. Keep a local copy for
        // the predecessor check, then prevent the versions from leaking into a
        // later configuration that happens to reuse this UUID.
        pendingLocalSaveVersions[deletedID] = nil
        let token = beginPersistenceMutation(for: deletedID)
        enqueuePersistence(operation: { [settingsStore, mutationCoordinator] in
            do {
                let persistedEnvelope = AIProviderSettingsNormalizer.normalized(
                    try settingsStore.loadAIProviderSettings()
                )
                let persisted = persistedEnvelope.aiProviders.first(where: { $0.id == deletedID })
                guard let persisted, acceptedProviderVersions.contains(persisted) else {
                    return AIProviderDeletePersistenceOutcome.stale(persistedEnvelope)
                }
                return .deleted(try mutationCoordinator.deleteProvider(id: deletedID))
            } catch {
                return .failed(error)
            }
        }, completion: { [weak self] result in
            guard let self, self.acceptsPersistenceMutation(for: deletedID, token: token) else { return }
            self.finishPersistenceMutation(for: deletedID, token: token)
            self.pendingLocalSaveVersions[deletedID] = nil
            switch result {
            case let .success(.deleted(envelope)):
                self.currentEnvelope = envelope
                self.editDrafts[deletedID] = nil
                self.catalogStates[deletedID] = nil
                self.connectionStates[deletedID] = nil
                if deletedProviderWasSelected || self.providerExists(self.selectedProviderID) == false {
                    // Deleting the selected/default provider must leave the UI in an
                    // explicit unconfigured state. Do not silently select the first
                    // remaining provider; that would change the runtime target
                    // without a user decision.
                    self.selectedProviderID = self.providerExists(envelope.defaultAIProviderID)
                        ? envelope.defaultAIProviderID
                        : BuiltInAIProvider.stacioRulesID
                }
                self.providerTableView.reloadData()
                self.syncProviderTableSelection()
                self.renderSelectedProvider()
            case let .success(.stale(envelope)):
                self.currentEnvelope = envelope
                self.editDrafts.removeAll()
                if self.providerExists(self.selectedProviderID) == false {
                    self.selectedProviderID = self.preferredProviderID()
                }
                _ = self.draft(for: self.selectedProviderID)
                self.configurationMutationErrorMessage = "供应商配置已在其他位置更改，已重新加载，请确认后再删除。"
                self.providerTableView.reloadData()
                self.syncProviderTableSelection()
                self.renderSelectedProvider()
            case let .success(.failed(error)), let .failure(error):
                self.configurationMutationErrorMessage = self.actionableMessage(for: error, apiKey: nil)
                self.renderSelectedProvider()
            }
        })
    }

    private func save(
        draft: AIProviderEditDraft,
        apiKeyUpdate: AIProviderAPIKeyUpdate,
        impact: AIProviderMutationImpact,
        completion: ((Result<AIProviderSettingsEnvelope, Error>) -> Void)? = nil
    ) {
        let providerID = draft.provider.id
        let previousDraft = editDrafts[providerID]
        let persistedSnapshot = persistedProvider(id: providerID)
        let localBase = persistedSnapshot ?? previousDraft?.provider ?? draft.provider
        let acceptedPredecessors = [persistedSnapshot, previousDraft?.provider].compactMap { $0 }
            + (pendingLocalSaveVersions[providerID] ?? [])
        let replacementAPIKey: String?
        if case let .replace(apiKey) = apiKeyUpdate {
            replacementAPIKey = apiKey
        } else {
            replacementAPIKey = nil
        }
        configurationMutationErrorMessage = nil
        // Every save writes the complete provider snapshot. Even a display
        // name or model-preference edit must therefore supersede pending
        // catalog/connection writes, otherwise an older full-snapshot result
        // can make the user's save conflict after it reaches persistence.
        invalidateRequests(for: providerID, catalog: true, connection: true)
        let token = beginPersistenceMutation(for: providerID)
        appendPendingLocalVersion(draft.provider)
        editDrafts[providerID] = draft
        if selectedProviderID == providerID {
            renderSelectedProvider()
        }
        enqueuePersistence(operation: { [settingsStore, mutationCoordinator] () -> AIProviderSavePersistenceOutcome in
            AIProviderConfigurationCoordinator.withSharedTransaction {
                do {
                    let persistedEnvelope = AIProviderSettingsNormalizer.normalized(
                        try settingsStore.loadAIProviderSettings()
                    )
                    guard let persistedProvider = persistedEnvelope.aiProviders.first(where: {
                        $0.id == providerID
                    }), acceptedPredecessors.contains(persistedProvider) else {
                        let credentialAvailability: AIProviderCredentialAvailability
                        do {
                            let persistedAPIKey = try mutationCoordinator.readAPIKey(for: providerID)
                            credentialAvailability = persistedAPIKey?.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty == false ? .available : .missing
                        } catch {
                            credentialAvailability = .failed
                        }
                        return .stale(
                            envelope: persistedEnvelope,
                            credentialAvailability: credentialAvailability
                        )
                    }
                    let providerToSave = Self.rebasedProvider(
                        base: localBase,
                        draft: draft.provider,
                        latest: persistedProvider,
                        impact: impact
                    )
                    return .saved(
                        try mutationCoordinator.saveProvider(
                            providerToSave,
                            apiKeyUpdate: apiKeyUpdate
                        )
                    )
                } catch {
                    let envelope = try? AIProviderSettingsNormalizer.normalized(
                        settingsStore.loadAIProviderSettings()
                    )
                    let credentialAvailability: AIProviderCredentialAvailability
                    do {
                        let persistedAPIKey = try mutationCoordinator.readAPIKey(for: providerID)
                        credentialAvailability = persistedAPIKey?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty == false ? .available : .missing
                    } catch {
                        credentialAvailability = .failed
                    }
                    return .failed(
                        error: error,
                        envelope: envelope,
                        credentialAvailability: credentialAvailability
                    )
                }
            }
        }, completion: { [weak self] result in
            guard let self, self.acceptsPersistenceMutation(for: providerID, token: token) else { return }
            self.finishPersistenceMutation(for: providerID, token: token)
            self.pendingLocalSaveVersions[providerID] = nil
            switch result {
            case let .success(.saved(envelope)):
                self.applySuccessfulProviderMutationEnvelope(
                    envelope,
                    providerID: providerID
                )
                if let savedProvider = envelope.aiProviders.first(where: { $0.id == providerID }) {
                    let credentialAvailability: AIProviderCredentialAvailability
                    switch apiKeyUpdate {
                    case .replace:
                        credentialAvailability = .available
                    case .remove:
                        credentialAvailability = .missing
                    case .unchanged:
                        credentialAvailability = draft.credentialAvailability
                    }
                    self.editDrafts[providerID] = AIProviderEditDraft(
                        provider: savedProvider,
                        credentialAvailability: credentialAvailability
                    )
                    if credentialAvailability == .loading {
                        self.loadCredentialAvailability(
                            for: providerID,
                            expectedProvider: savedProvider
                        )
                    }
                }
                self.providerTableView.reloadData()
                self.syncProviderTableSelection()
                self.renderSelectedProvider()
            case let .success(.stale(envelope, credentialAvailability)):
                self.currentEnvelope = envelope
                if let persistedProvider = self.persistedProvider(id: providerID) {
                    self.editDrafts[providerID] = AIProviderEditDraft(
                        provider: persistedProvider,
                        credentialAvailability: credentialAvailability
                    )
                } else {
                    self.editDrafts[providerID] = nil
                }
                if self.providerExists(self.selectedProviderID) == false {
                    self.selectedProviderID = self.preferredProviderID()
                }
                self.configurationMutationErrorMessage = AIProviderManagementMutationError
                    .providerChanged
                    .errorDescription
                self.providerTableView.reloadData()
                self.syncProviderTableSelection()
                self.renderSelectedProvider()
            case let .success(.failed(error, envelope, credentialAvailability)):
                if let envelope {
                    self.currentEnvelope = envelope
                }
                if let persistedProvider = self.persistedProvider(id: providerID) {
                    self.editDrafts[providerID] = AIProviderEditDraft(
                        provider: persistedProvider,
                        credentialAvailability: credentialAvailability
                    )
                } else {
                    self.editDrafts[providerID] = nil
                }
                self.configurationMutationErrorMessage = self.actionableMessage(
                    for: error,
                    apiKey: replacementAPIKey
                )
                self.renderSelectedProvider()
            case let .failure(error):
                self.editDrafts[providerID] = previousDraft
                self.configurationMutationErrorMessage = self.actionableMessage(
                    for: error,
                    apiKey: replacementAPIKey
                )
                self.renderSelectedProvider()
            }
            switch result {
            case let .success(.saved(envelope)):
                completion?(.success(envelope))
            case .success(.stale):
                completion?(.failure(AIProviderManagementMutationError.providerChanged))
            case let .success(.failed(error, _, _)), let .failure(error):
                completion?(.failure(error))
            }
        })
    }

    private func refreshSelectedProviderModels() {
        let providerID = selectedProviderID
        guard providerID != BuiltInAIProvider.stacioRulesID,
              isCatalogLoading(providerID) == false,
              draft(for: providerID) != nil
        else {
            return
        }

        persistPendingAPIKeyIfNeeded { [weak self] persisted in
            guard let self, persisted, self.selectedProviderID == providerID,
                  let currentDraft = self.draft(for: providerID)
            else { return }
            self.beginRefreshSelectedProviderModels(
                providerID: providerID,
                draft: currentDraft
            )
        }
    }

    private func beginRefreshSelectedProviderModels(
        providerID: UUID,
        draft: AIProviderEditDraft
    ) {
        guard providerID == selectedProviderID,
              isCatalogLoading(providerID) == false
        else { return }

        guard supportsModelDiscovery(for: draft.provider) else {
            catalogStates[providerID] = .failed("当前供应商不支持自动获取模型，请使用其受支持的配置方式。")
            renderSelectedProvider()
            return
        }

        readCredential(for: draft.provider) { [weak self] credentialOutcome in
            guard let self, self.selectedProviderID == providerID else { return }
            let apiKey: String?
            switch credentialOutcome {
            case let .available(value):
                apiKey = value
            case .missing:
                if self.requiresCredential(for: draft.provider) {
                    self.catalogStates[providerID] = .failed("获取模型前必须先保存 API Key。")
                    self.renderSelectedProvider()
                    return
                }
                apiKey = nil
            case .stale:
                self.catalogStates[providerID] = .idle
                if self.selectedProviderID == providerID {
                    self.renderSelectedProvider()
                }
                return
            case let .failed(error):
                self.catalogStates[providerID] = .failed(
                    self.actionableMessage(for: error, apiKey: nil)
                )
                self.renderSelectedProvider()
                return
            }
            self.authorizeCredentialUseAsync(
                for: draft.provider,
                purpose: L10n.Settings.aiCredentialOriginModelDiscoveryPurpose
            ) { [weak self] authorization in
                guard let self, self.selectedProviderID == providerID else { return }
                let providerSnapshot: AIProviderConfiguration
                switch authorization {
                case let .authorized(provider):
                    providerSnapshot = provider
                case .cancelled:
                    self.catalogStates[providerID] = .failed(L10n.Settings.aiCredentialOriginCancelled)
                    self.renderSelectedProvider()
                    return
                case let .failed(message):
                    self.catalogStates[providerID] = .failed(message)
                    self.renderSelectedProvider()
                    return
                }
                self.startCatalogRequest(
                    providerID: providerID,
                    providerSnapshot: providerSnapshot,
                    apiKey: apiKey
                )
            }
        }
    }

    private func startCatalogRequest(
        providerID: UUID,
        providerSnapshot: AIProviderConfiguration,
        apiKey: String?
    ) {
        let token = UUID()
        catalogRequestTokens[providerID] = token
        catalogRequestSnapshots[providerID] = AIProviderCatalogRequestSnapshot(
            provider: providerSnapshot,
            apiKey: apiKey
        )
        catalogStates[providerID] = .loading
        renderSelectedProvider()

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
        guard acceptsCatalogResult(providerID: providerID, token: token),
              let snapshot = catalogRequestSnapshots[providerID]
        else {
            return
        }
        switch result {
        case let .success(entries):
            let synchronizedAt = now()
            let mergedModels = AIProviderModelCatalogMerger.merge(
                existing: snapshot.provider.models,
                fetchedEntries: entries
            )
            let acceptedCatalog = mergedModels.contains(where: \.wasReturnedByLatestCatalog)
            mutateCatalogRequestAsync(
                providerID: providerID,
                token: token,
                snapshot: snapshot
            ) { provider in
                var updated = provider
                guard acceptedCatalog else {
                    updated.lastModelSyncAt = nil
                    for index in updated.models.indices where !updated.models[index].isManual {
                        updated.models[index].wasReturnedByLatestCatalog = false
                    }
                    return updated
                }
                updated.models = mergedModels
                if let defaultModelID = updated.defaultModelID,
                   updated.models.contains(where: {
                       $0.id == defaultModelID
                           && $0.isEnabled
                           && ($0.isManual == false || $0.lastVerifiedAt != nil)
                   }) == false {
                    updated.defaultModelID = nil
                    updated.isEnabled = false
                    updated.lastVerifiedAt = nil
                }
                updated.lastModelSyncAt = synchronizedAt
                return updated
            } completion: { [weak self] outcome in
                self?.applyCatalogMutationOutcome(
                    outcome,
                    providerID: providerID,
                    apiKey: apiKey,
                    successState: acceptedCatalog ? .loaded : .failed(
                        self?.actionableMessage(
                            for: AIAssistantProviderError.invalidResponse,
                            apiKey: apiKey
                        ) ?? "模型目录响应无效"
                    )
                )
            }
        case let .failure(error):
            mutateCatalogRequestAsync(
                providerID: providerID,
                token: token,
                snapshot: snapshot
            ) { provider in
                var updated = provider
                updated.lastModelSyncAt = nil
                for index in updated.models.indices where !updated.models[index].isManual {
                    updated.models[index].wasReturnedByLatestCatalog = false
                }
                return updated
            } completion: { [weak self] outcome in
                self?.applyCatalogMutationOutcome(
                    outcome,
                    providerID: providerID,
                    apiKey: apiKey,
                    successState: .failed(
                        self?.actionableMessage(for: error, apiKey: apiKey) ?? "获取模型失败"
                    )
                )
            }
        }
    }

    private func mutateCatalogRequestAsync(
        providerID: UUID,
        token: UUID,
        snapshot: AIProviderCatalogRequestSnapshot,
        transform: @escaping (AIProviderConfiguration) -> AIProviderConfiguration,
        completion: @escaping (AIProviderRequestMutationOutcome) -> Void
    ) {
        guard acceptsCatalogResult(providerID: providerID, token: token) else {
            completion(.stale)
            return
        }
        let expectedProvider = transform(snapshot.provider)
        appendPendingLocalVersion(expectedProvider)
        let settingsStore = self.settingsStore
        let mutationCoordinator = self.mutationCoordinator
        let persistenceExecutor = self.persistenceExecutor
        let mainExecutor = self.mainExecutor
        persistenceExecutor {
            let outcome: AIProviderRequestMutationOutcome = AIProviderConfigurationCoordinator.withSharedTransaction {
                let persistedProvider: AIProviderConfiguration
                let persistedAPIKey: String?
                do {
                    let persistedEnvelope = AIProviderSettingsNormalizer.normalized(
                        try settingsStore.loadAIProviderSettings()
                    )
                    guard let provider = persistedEnvelope.aiProviders.first(where: {
                        $0.id == providerID
                    }) else {
                        return .stale
                    }
                    persistedProvider = provider
                    persistedAPIKey = try mutationCoordinator.readAPIKey(for: providerID)
                        .flatMap { value in
                            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            return normalized.isEmpty ? nil : normalized
                        }
                } catch {
                    return .stale
                }
                guard persistedProvider == snapshot.provider,
                      persistedAPIKey == snapshot.apiKey
                else {
                    return .stale
                }
                do {
                    let envelope = try mutationCoordinator.saveProvider(
                        expectedProvider,
                        apiKeyUpdate: .unchanged
                    )
                    return .applied(
                        envelope: envelope,
                        hasStoredAPIKey: snapshot.apiKey?.isEmpty == false
                    )
                } catch {
                    return .failed(error)
                }
            }
            mainExecutor { [weak self] in
                guard let self else { return }
                let acceptsResult = self.acceptsCatalogResult(
                    providerID: providerID,
                    token: token
                )
                switch outcome {
                case .applied where acceptsResult == false:
                    // The write reached persistence after a local edit
                    // invalidated the request. Retain it as a legal local
                    // predecessor so that the newer edit can still commit.
                    return
                case .applied, .stale, .failed:
                    self.removePendingLocalVersion(expectedProvider)
                }
                guard acceptsResult else { return }
                completion(outcome)
            }
        }
    }

    private func applyCatalogMutationOutcome(
        _ outcome: AIProviderRequestMutationOutcome,
        providerID: UUID,
        apiKey: String?,
        successState: AIProviderCatalogUIState
    ) {
        clearCatalogRequest(providerID: providerID)
        switch outcome {
        case let .applied(envelope, hasStoredAPIKey):
            applySuccessfulProviderMutationEnvelope(envelope, providerID: providerID)
            if let saved = envelope.aiProviders.first(where: { $0.id == providerID }) {
                editDrafts[providerID] = AIProviderEditDraft(
                    provider: saved,
                    credentialAvailability: hasStoredAPIKey ? .available : .missing
                )
            }
            catalogStates[providerID] = successState
            providerTableView.reloadData()
        case .stale:
            catalogStates[providerID] = .idle
        case let .failed(error):
            catalogStates[providerID] = .failed(actionableMessage(for: error, apiKey: apiKey))
        }
        if selectedProviderID == providerID {
            renderSelectedProvider()
        }
    }

    private func clearCatalogRequest(providerID: UUID) {
        catalogRequestTokens[providerID] = nil
        catalogRequestSnapshots[providerID] = nil
    }

    private func acceptsCatalogResult(providerID: UUID, token: UUID) -> Bool {
        catalogRequestTokens[providerID] == token
            && catalogRequestSnapshots[providerID] != nil
            && currentEnvelope.aiProviders.contains(where: { $0.id == providerID })
    }

    private func testSelectedProviderConnection() {
        let providerID = selectedProviderID
        guard providerID != BuiltInAIProvider.stacioRulesID,
              isConnectionTesting(providerID) == false,
              draft(for: providerID) != nil
        else {
            return
        }
        persistPendingAPIKeyIfNeeded { [weak self] persisted in
            guard let self, persisted, self.selectedProviderID == providerID,
                  let currentDraft = self.draft(for: providerID)
            else { return }
            self.beginTestSelectedProviderConnection(
                providerID: providerID,
                draft: currentDraft
            )
        }
    }

    private func beginTestSelectedProviderConnection(
        providerID: UUID,
        draft: AIProviderEditDraft
    ) {
        guard providerID == selectedProviderID,
              isConnectionTesting(providerID) == false
        else { return }
        let modelID = selectedModelID
            .flatMap { candidate in draft.provider.models.contains { $0.id == candidate } ? candidate : nil }
            ?? draft.provider.defaultModelID
            ?? draft.provider.models.first(where: {
                AIProviderRuntimeEligibility.isModelRunnable($0, in: draft.provider)
            })?.id
        guard let modelID, modelID.isEmpty == false else {
            connectionStates[providerID] = .failed("请先选择一个模型作为测试目标。")
            renderSelectedProvider()
            return
        }

        readCredential(for: draft.provider) { [weak self] credentialOutcome in
            guard let self, self.selectedProviderID == providerID else { return }
            let apiKey: String?
            switch credentialOutcome {
            case let .available(value):
                apiKey = value
            case .missing:
                if self.requiresCredential(for: draft.provider) {
                    self.connectionStates[providerID] = .failed("测试连接前必须先保存 API Key。")
                    self.renderSelectedProvider()
                    return
                }
                apiKey = nil
            case .stale:
                self.connectionStates[providerID] = .idle
                if self.selectedProviderID == providerID {
                    self.renderSelectedProvider()
                }
                return
            case let .failed(error):
                self.connectionStates[providerID] = .failed(
                    self.actionableMessage(for: error, apiKey: nil)
                )
                self.renderSelectedProvider()
                return
            }
            self.authorizeCredentialUseAsync(
                for: draft.provider,
                purpose: L10n.Settings.aiCredentialOriginConnectionTestPurpose
            ) { [weak self] authorization in
                guard let self, self.selectedProviderID == providerID else { return }
                let providerSnapshot: AIProviderConfiguration
                switch authorization {
                case let .authorized(provider):
                    providerSnapshot = provider
                case .cancelled:
                    self.connectionStates[providerID] = .failed(L10n.Settings.aiCredentialOriginCancelled)
                    self.renderSelectedProvider()
                    return
                case let .failed(message):
                    self.connectionStates[providerID] = .failed(message)
                    self.renderSelectedProvider()
                    return
                }
                self.startConnectionRequest(
                    providerID: providerID,
                    providerSnapshot: providerSnapshot,
                    modelID: modelID,
                    apiKey: apiKey
                )
            }
        }
    }

    private func startConnectionRequest(
        providerID: UUID,
        providerSnapshot: AIProviderConfiguration,
        modelID: String,
        apiKey: String?
    ) {

        let token = UUID()
        connectionRequestTokens[providerID] = token
        connectionRequestModelIDs[providerID] = modelID
        connectionStates[providerID] = .testing
        renderSelectedProvider()

        connectionRequestSnapshots[providerID] = AIProviderConnectionRequestSnapshot(
            provider: providerSnapshot,
            modelID: modelID,
            apiKey: apiKey
        )
        let tester = UncheckedAIProviderConnectionTesterBox(connectionTester)
        let mainExecutor = self.mainExecutor
        backgroundExecutor { [weak self] in
            let result = Result {
                try tester.value.testConnection(
                    provider: providerSnapshot,
                    modelID: modelID,
                    apiKey: apiKey
                )
            }
            mainExecutor {
                self?.finishConnectionTest(
                    providerID: providerID,
                    token: token,
                    modelID: modelID,
                    apiKey: apiKey,
                    result: result
                )
            }
        }
    }

    private func finishConnectionTest(
        providerID: UUID,
        token: UUID,
        modelID: String,
        apiKey: String?,
        result: Result<AIAssistantConnectionTestResult, Error>
    ) {
        guard connectionRequestTokens[providerID] == token,
              connectionRequestModelIDs[providerID] == modelID,
              let snapshot = connectionRequestSnapshots[providerID],
              snapshot.modelID == modelID,
              snapshot.apiKey == apiKey,
              currentEnvelope.aiProviders.contains(where: { $0.id == providerID })
        else {
            return
        }

        switch result {
        case let .success(testResult):
            let verifiedAt = now()
            mutateConnectionRequestAsync(
                providerID: providerID,
                token: token,
                snapshot: snapshot
            ) { provider in
                var updated = provider
                if let index = updated.models.firstIndex(where: { $0.id == modelID }) {
                    updated.models[index].lastVerifiedAt = verifiedAt
                }
                if updated.defaultModelID == nil {
                    updated.defaultModelID = modelID
                }
                if updated.defaultModelID == modelID {
                    updated.lastVerifiedAt = verifiedAt
                    updated.isEnabled = true
                }
                return updated
            } completion: { [weak self] outcome in
                self?.applyConnectionMutationOutcome(
                    outcome,
                    providerID: providerID,
                    apiKey: apiKey,
                    state: .succeeded(
                        self?.redactedMessage(testResult.message, apiKey: apiKey) ?? "连接成功"
                    )
                )
            }
        case let .failure(error):
            mutateConnectionRequestAsync(
                providerID: providerID,
                token: token,
                snapshot: snapshot
            ) { provider in
                var updated = provider
                if let index = updated.models.firstIndex(where: { $0.id == modelID }) {
                    updated.models[index].lastVerifiedAt = nil
                }
                if updated.defaultModelID == modelID {
                    updated.lastVerifiedAt = nil
                    updated.isEnabled = false
                }
                return updated
            } completion: { [weak self] outcome in
                self?.applyConnectionMutationOutcome(
                    outcome,
                    providerID: providerID,
                    apiKey: apiKey,
                    state: .failed(
                        self?.actionableMessage(for: error, apiKey: apiKey) ?? "连接测试失败"
                    )
                )
            }
        }
    }

    private func mutateConnectionRequestAsync(
        providerID: UUID,
        token: UUID,
        snapshot: AIProviderConnectionRequestSnapshot,
        transform: @escaping (AIProviderConfiguration) -> AIProviderConfiguration,
        completion: @escaping (AIProviderRequestMutationOutcome) -> Void
    ) {
        guard connectionRequestTokens[providerID] == token,
              connectionRequestModelIDs[providerID] == snapshot.modelID,
              connectionRequestSnapshots[providerID] == snapshot
        else {
            completion(.stale)
            return
        }
        let expectedProvider = transform(snapshot.provider)
        appendPendingLocalVersion(expectedProvider)
        let settingsStore = self.settingsStore
        let mutationCoordinator = self.mutationCoordinator
        let persistenceExecutor = self.persistenceExecutor
        let mainExecutor = self.mainExecutor
        persistenceExecutor {
            let outcome: AIProviderRequestMutationOutcome = AIProviderConfigurationCoordinator.withSharedTransaction {
                let persistedProvider: AIProviderConfiguration
                let persistedAPIKey: String?
                do {
                    let persistedEnvelope = AIProviderSettingsNormalizer.normalized(
                        try settingsStore.loadAIProviderSettings()
                    )
                    guard let provider = persistedEnvelope.aiProviders.first(where: {
                        $0.id == providerID
                    }) else {
                        return .stale
                    }
                    persistedProvider = provider
                    persistedAPIKey = try mutationCoordinator.readAPIKey(for: providerID)
                        .flatMap { value in
                            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            return normalized.isEmpty ? nil : normalized
                        }
                } catch {
                    return .stale
                }
                guard persistedProvider == snapshot.provider,
                      persistedAPIKey == snapshot.apiKey
                else {
                    return .stale
                }
                do {
                    let envelope = try mutationCoordinator.saveProvider(
                        expectedProvider,
                        apiKeyUpdate: .unchanged
                    )
                    return .applied(
                        envelope: envelope,
                        hasStoredAPIKey: snapshot.apiKey?.isEmpty == false
                    )
                } catch {
                    return .failed(error)
                }
            }
            mainExecutor { [weak self] in
                guard let self else { return }
                let acceptsResult = self.connectionRequestTokens[providerID] == token
                    && self.connectionRequestModelIDs[providerID] == snapshot.modelID
                    && self.connectionRequestSnapshots[providerID] == snapshot
                switch outcome {
                case .applied where acceptsResult == false:
                    return
                case .applied, .stale, .failed:
                    self.removePendingLocalVersion(expectedProvider)
                }
                guard acceptsResult else { return }
                completion(outcome)
            }
        }
    }

    private func applyConnectionMutationOutcome(
        _ outcome: AIProviderRequestMutationOutcome,
        providerID: UUID,
        apiKey: String?,
        state: AIProviderConnectionUIState
    ) {
        clearConnectionRequest(providerID: providerID)
        switch outcome {
        case let .applied(envelope, hasStoredAPIKey):
            applySuccessfulProviderMutationEnvelope(envelope, providerID: providerID)
            if let saved = envelope.aiProviders.first(where: { $0.id == providerID }) {
                editDrafts[providerID] = AIProviderEditDraft(
                    provider: saved,
                    credentialAvailability: hasStoredAPIKey ? .available : .missing
                )
            }
            connectionStates[providerID] = state
            providerTableView.reloadData()
        case .stale:
            connectionStates[providerID] = .idle
        case let .failed(error):
            connectionStates[providerID] = .failed(actionableMessage(for: error, apiKey: apiKey))
        }
        if selectedProviderID == providerID {
            renderSelectedProvider()
        }
    }

    private func clearConnectionRequest(providerID: UUID) {
        connectionRequestTokens[providerID] = nil
        connectionRequestModelIDs[providerID] = nil
        connectionRequestSnapshots[providerID] = nil
    }

    private func renderSelectedProvider() {
        let provider = providerForDisplay(id: selectedProviderID)
        let descriptor = provider.flatMap(catalogDescriptor(for:))
        reconcileSelectedModel()
        concealAPIKey()

        providerNameLabel.stringValue = provider.map(displayName(for:)) ?? "供应商不可用"
        updateProviderStatus(provider: provider)
        updateProviderActivationButton(provider: provider)

        displayNameField.stringValue = provider.map(displayName(for:)) ?? ""
        baseURLField.stringValue = provider.map(displayedBaseURL(for:)) ?? ""
        if let draft = editDrafts[selectedProviderID], draft.hasStoredAPIKey {
            apiKeyField.stringValue = Self.maskedAPIKeyPlaceholder
        } else {
            apiKeyField.stringValue = ""
        }

        let editable = provider != nil && isSettingsLoading == false
        displayNameField.isEditable = editable
        displayNameField.isSelectable = editable
        displayNameField.isEnabled = editable
        baseURLField.isEditable = editable
        baseURLField.isSelectable = editable
        baseURLField.isEnabled = editable
        [apiKeyField, userAgentField, retryCountField, requestTimeoutField].forEach {
            $0.isEditable = editable
            $0.isSelectable = editable
            $0.isEnabled = editable
        }
        let credentialEditable = editable && descriptor?.authenticationKind != CatalogAuthenticationKind.none
        apiKeyField.isEditable = credentialEditable
        apiKeyField.isSelectable = credentialEditable
        apiKeyField.isEnabled = credentialEditable
        apiKeyRow?.isHidden = editable && descriptor?.authenticationKind == CatalogAuthenticationKind.none
        compatibilityProtocolPopup.isEnabled = editable
        retryCountStepper.isEnabled = editable
        requestTimeoutStepper.isEnabled = editable
        updateAPIKeyActionAvailability(editable: editable)
        providerTableView.isEnabled = isSettingsLoading == false
        addProviderButton.isEnabled = isSettingsLoading == false
        removeProviderButton.isEnabled = editable
        moreProviderButton.isEnabled = editable
        exportProviderButton.isEnabled = isSettingsLoading == false
            && configurationIORequestToken == nil
        importProviderButton.isEnabled = isSettingsLoading == false
            && configurationIORequestToken == nil
        if let action = provider.flatMap(primaryWebsiteAction(for:)) {
            visitWebsiteButton.title = action.title
            visitWebsiteButton.toolTip = "打开 \(action.title)"
            visitWebsiteButton.isHidden = false
        } else {
            visitWebsiteButton.isHidden = true
        }
        let canRestoreOfficialURL = editable
            && descriptor?.suggestedBaseURL?.isEmpty == false
            && provider?.baseURL != descriptor?.suggestedBaseURL
        restoreOfficialURLButton.isHidden = canRestoreOfficialURL == false
        restoreOfficialURLButton.isEnabled = canRestoreOfficialURL
        updateAsyncActionAvailability(provider: provider, editable: editable)
        modelSearchField.isEnabled = editable
        let allowsManualModels = provider.map(allowsManualModelIDs(for:)) ?? false
        manualModelRow?.isHidden = allowsManualModels == false
        manualModelField.isEnabled = editable && allowsManualModels
        addManualModelButton.isEnabled = editable && allowsManualModels

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
        if isSettingsLoading {
            providerStatusLabel.stringValue = "正在加载供应商设置..."
            providerStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
            return
        }
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
        currentEnvelope.aiProviders
            .first(where: { $0.id != BuiltInAIProvider.stacioRulesID })?
            .id ?? BuiltInAIProvider.stacioRulesID
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
        let draft = AIProviderEditDraft(provider: provider, credentialAvailability: .loading)
        editDrafts[id] = draft
        loadCredentialAvailability(for: id, expectedProvider: provider)
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
            isRecommended: false
        )
    }

    private func displayName(for provider: AIProviderConfiguration) -> String {
        provider.displayName
    }

    private func displayedBaseURL(for provider: AIProviderConfiguration) -> String {
        provider.baseURL
    }

    private func providerStatusText(_ provider: AIProviderConfiguration) -> String {
        if provider.defaultModelID == nil {
            return "未选择默认模型"
        }
        if provider.lastVerifiedAt == nil {
            return "待验证"
        }
        if provider.isEnabled == false {
            return "已停用"
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
        if provider.lastVerifiedAt == nil || provider.defaultModelID == nil {
            return StacioDesignSystem.theme.warningColor
        }
        if provider.isEnabled == false {
            return StacioDesignSystem.theme.secondaryTextColor
        }
        return StacioDesignSystem.theme.successColor
    }

    private func updateProviderActivationButton(provider: AIProviderConfiguration?) {
        guard let provider else {
            providerActivationButton.title = "验证并启用"
            providerActivationButton.image = NSImage(
                systemSymbolName: "checkmark.shield",
                accessibilityDescription: nil
            )
            providerActivationButton.toolTip = "供应商不可用"
            providerActivationButton.isEnabled = false
            return
        }

        if provider.isEnabled {
            providerActivationButton.title = "停用"
            providerActivationButton.image = NSImage(
                systemSymbolName: "pause.circle",
                accessibilityDescription: nil
            )
            providerActivationButton.toolTip = "停用当前供应商"
            providerActivationButton.isEnabled = isSettingsLoading == false
                && isConnectionTesting(provider.id) == false
        } else if provider.lastVerifiedAt != nil, provider.defaultModelID != nil {
            providerActivationButton.title = "启用"
            providerActivationButton.image = NSImage(
                systemSymbolName: "play.circle",
                accessibilityDescription: nil
            )
            providerActivationButton.toolTip = "启用当前供应商"
            providerActivationButton.isEnabled = isSettingsLoading == false
        } else {
            providerActivationButton.title = "验证并启用"
            providerActivationButton.image = NSImage(
                systemSymbolName: "checkmark.shield",
                accessibilityDescription: nil
            )
            providerActivationButton.toolTip = "验证默认模型并启用当前供应商"
            providerActivationButton.isEnabled = canTestConnection(provider)
                && isConnectionTesting(provider.id) == false
        }
        providerActivationButton.setAccessibilityLabel(providerActivationButton.toolTip)
    }

    private func modelStatusText(_ model: AIProviderModelConfiguration) -> String {
        if model.isManual {
            return model.lastVerifiedAt == nil ? "手动待测试" : "手动已测试"
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
        if catalog || connection {
            // Credential reads and origin approval are part of the request
            // preflight. A request-sensitive edit must stop their late
            // callbacks from starting transport with the previous snapshot.
            credentialRequestTokens[providerID] = nil
            credentialGateTokens[providerID] = nil
        }
        if catalog {
            clearCatalogRequest(providerID: providerID)
            catalogStates[providerID] = .idle
        }
        if connection {
            clearConnectionRequest(providerID: providerID)
            connectionStates[providerID] = .idle
        }
    }

    private func invalidateAllRequests() {
        catalogRequestTokens.removeAll()
        catalogRequestSnapshots.removeAll()
        connectionRequestTokens.removeAll()
        connectionRequestModelIDs.removeAll()
        connectionRequestSnapshots.removeAll()
        catalogStates = catalogStates.mapValues { _ in .idle }
        connectionStates = connectionStates.mapValues { _ in .idle }
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
        let modelCandidateExists = provider.map(connectionTestModelExists) ?? false
        let credentialReady = provider.map(isCredentialReady) ?? false
        testConnectionButton.isEnabled = editable
            && modelCandidateExists
            && credentialReady
            && isConnectionTesting(providerID) == false
        refreshModelsButton.isEnabled = editable
            && provider.map(supportsModelDiscovery(for:)) == true
            && credentialReady
            && isCatalogLoading(providerID) == false
    }

    private func canTestConnection(_ provider: AIProviderConfiguration) -> Bool {
        connectionTestModelExists(provider) && isCredentialReady(provider)
    }

    private func connectionTestModelExists(_ provider: AIProviderConfiguration) -> Bool {
        if let selectedModelID,
           provider.models.contains(where: { $0.id == selectedModelID }) {
            return true
        }
        if let defaultModelID = provider.defaultModelID,
           provider.models.contains(where: { $0.id == defaultModelID }) {
            return true
        }
        return provider.models.contains {
            AIProviderRuntimeEligibility.isModelRunnable($0, in: provider)
        }
    }

    private func isCredentialReady(_ provider: AIProviderConfiguration) -> Bool {
        !requiresCredential(for: provider)
            || editDrafts[provider.id]?.hasStoredAPIKey == true
            || pendingAPIKeyInput() != nil
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
        Self.clearVerificationAndCatalogTimestampsForImport(in: &provider)
    }

    nonisolated private static func clearVerificationAndCatalogTimestampsForImport(
        in provider: inout AIProviderConfiguration
    ) {
        provider.isEnabled = false
        provider.lastVerifiedAt = nil
        provider.lastModelSyncAt = nil
        for index in provider.models.indices {
            provider.models[index].lastVerifiedAt = nil
            if provider.models[index].isManual == false {
                provider.models[index].wasReturnedByLatestCatalog = false
            }
        }
    }

    private func catalogDescriptor(for provider: AIProviderConfiguration) -> NativeRuntimeCatalogEntry? {
        if let catalogID = provider.catalogID,
           let descriptor = runtimeCatalog.nativeRuntimeEntry(catalogID: catalogID) {
            return descriptor
        }

        let normalizedBaseURL = OpenAICompatibleAIAssistantProvider
            .normalizedBaseURL(from: provider.baseURL)?
            .absoluteString
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let exactLegacyMatch = runtimeCatalog.providersForCreation().first { descriptor in
            guard descriptor.legacyProfileRawValue?.caseInsensitiveCompare(provider.profile.rawValue) == .orderedSame,
                  let suggested = descriptor.suggestedBaseURL,
                  let normalizedSuggested = OpenAICompatibleAIAssistantProvider
                    .normalizedBaseURL(from: suggested)?.absoluteString.lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            else { return false }
            return normalizedBaseURL == normalizedSuggested
        }
        if let exactLegacyMatch { return .provider(exactLegacyMatch) }

        // Legacy OpenAI-compatible configurations with an arbitrary endpoint
        // are treated as the catalog's explicit custom endpoint, never as a
        // different hosted provider.
        if provider.profile == .openAICompatible {
            return runtimeCatalog.providersForCreation().first {
                $0.catalogID == "provider.openai-compatible.custom"
            }.map(NativeRuntimeCatalogEntry.provider)
        }
        return nil
    }

    private func primaryWebsiteAction(for provider: AIProviderConfiguration) -> WebsiteActionEntry? {
        runtimeCatalog.primaryWebsiteAction(
            ownerCatalogID: catalogDescriptor(for: provider)?.catalogID
        )
    }

    private func allowsManualModelIDs(for provider: AIProviderConfiguration) -> Bool {
        if let descriptor = catalogDescriptor(for: provider) {
            // A legacy provider without an immutable catalog identity may have
            // relied on the old manual-model path. Keep that migration path
            // available; newly created catalog-backed providers use the
            // descriptor's explicit capability contract.
            if provider.catalogID == nil,
               descriptor.catalogID == "provider.openai-compatible.custom",
               provider.profile == .openAICompatible {
                return true
            }
            return descriptor.allowsManualModelIDs
        }
        return false
    }

    private func supportsModelDiscovery(for provider: AIProviderConfiguration) -> Bool {
        guard let descriptor = catalogDescriptor(for: provider) else {
            // Preserve legacy configurations until they are explicitly mapped
            // to a Catalog entry; their existing OpenAI-compatible loader is a
            // known capability.
            return provider.profile.usesModelInterface
        }
        if provider.catalogID == nil,
           descriptor.catalogID == "provider.openai-compatible.custom",
           provider.profile.usesModelInterface {
            // Preserve V1 behavior for unmapped persisted configurations. The
            // explicit catalog-backed custom provider remains manualOnly.
            return true
        }
        switch descriptor.modelDiscoveryStrategy {
        case .openAIModels, .anthropicModels:
            return descriptor.protocolFamily == .openAICompatible
                || descriptor.protocolFamily == .anthropicMessages
        case .manualOnly, .cliManaged, .unavailable:
            return false
        }
    }

    private func requiresCredential(for provider: AIProviderConfiguration) -> Bool {
        catalogDescriptor(for: provider)?.requiresCredential ?? true
    }

    private enum CredentialOriginGateResult {
        case authorized(AIProviderConfiguration)
        case cancelled
        case failed(String)
    }

    private func authorizeCredentialUseAsync(
        for provider: AIProviderConfiguration,
        purpose: String,
        completion: @escaping (CredentialOriginGateResult) -> Void
    ) {
        switch AIProviderCredentialOriginPolicy.authorization(
            for: provider,
            runtimeCatalog: runtimeCatalog
        ) {
        case .confirmationNotRequired, .confirmed:
            completion(.authorized(provider))
        case .invalidBaseURL:
            completion(.failed(AIAssistantProviderError.invalidBaseURL.errorDescription ?? "AI Base URL 无效"))
        case let .confirmationRequired(origin):
            let request = AIProviderCredentialOriginConfirmationRequest(
                providerName: provider.displayName,
                origin: origin,
                credentialPurpose: purpose
            )
            guard credentialOriginConfirmationHandler(request) else {
                completion(.cancelled)
                return
            }
            var confirmedProvider = provider
            confirmedProvider.confirmedCredentialOrigin = origin
            let providerID = provider.id
            let token = UUID()
            let generation = lifecycleGeneration
            credentialGateTokens[providerID] = token
            // Keep the approval write in the same local version chain as
            // ordinary saves. If the user edits or deletes immediately after
            // confirming, its compare-and-save may legitimately see this
            // approved version in persistent storage.
            appendPendingLocalVersion(confirmedProvider)
            enqueuePersistence(operation: { [settingsStore, mutationCoordinator] in
                do {
                    let persisted = AIProviderSettingsNormalizer.normalized(
                        try settingsStore.loadAIProviderSettings()
                    ).aiProviders.first(where: { $0.id == providerID })
                    guard persisted == provider else {
                        return AIProviderCredentialConfirmationPersistenceOutcome.stale
                    }
                    return .saved(
                        try mutationCoordinator.saveProvider(
                            confirmedProvider,
                            apiKeyUpdate: .unchanged
                        )
                    )
                } catch {
                    return .failed(error)
                }
            }, completion: { [weak self] result in
                guard let self, self.lifecycleGeneration == generation else { return }
                let acceptsResult = self.credentialGateTokens[providerID] == token
                if case .success(.saved) = result, acceptsResult == false {
                    return
                }
                self.removePendingLocalVersion(confirmedProvider)
                guard acceptsResult else { return }
                self.credentialGateTokens[providerID] = nil
                switch result {
                case let .success(.saved(envelope)):
                    guard let saved = envelope.aiProviders.first(where: {
                        $0.id == provider.id
                    }) else {
                        completion(.failed("无法保存 API Key 发送目标确认。"))
                        return
                    }
                    self.applySuccessfulProviderMutationEnvelope(
                        envelope,
                        providerID: providerID
                    )
                    let availability = self.editDrafts[provider.id]?.credentialAvailability
                        ?? .loading
                    if self.editDrafts[provider.id]?.provider == provider
                        || self.editDrafts[provider.id]?.provider == confirmedProvider
                        || self.editDrafts[provider.id] == nil {
                        self.editDrafts[provider.id] = AIProviderEditDraft(
                            provider: saved,
                            credentialAvailability: availability
                        )
                    }
                    self.providerTableView.reloadData()
                    completion(.authorized(saved))
                case .success(.stale):
                    completion(.failed("供应商配置已变化，请重试。"))
                case let .success(.failed(error)), let .failure(error):
                    completion(.failed(self.actionableMessage(for: error, apiKey: nil)))
                }
            })
        }
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
