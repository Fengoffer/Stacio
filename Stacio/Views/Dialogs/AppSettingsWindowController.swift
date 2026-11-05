import AppKit
import StacioAgentBridge
import StacioCoreBindings
import UniformTypeIdentifiers

@MainActor
final class StacioShortcutRecorderField: NSTextField {
    var onBindingChanged: ((StacioShortcutBinding) -> Void)?
    var binding = StacioShortcutBinding(key: "") {
        didSet { stringValue = binding.displayString }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        alignment = .center
        isBezeled = true
        bezelStyle = .roundedBezel
        focusRingType = .exterior
        stringValue = binding.displayString
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        stringValue = "按下快捷键…"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            stringValue = binding.displayString
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.intersection([.command, .option, .control]).isEmpty == false else {
            NSSound.beep()
            return
        }
        let key: String
        switch event.keyCode {
        case 36, 76: key = "return"
        case 48: key = "tab"
        case 49: key = " "
        case 51: key = "delete"
        case 117: key = "forwarddelete"
        case 123: key = "left"
        case 124: key = "right"
        case 125: key = "down"
        case 126: key = "up"
        case 115: key = "home"
        case 119: key = "end"
        case 116: key = "pageup"
        case 121: key = "pagedown"
        case 122: key = "f1"
        case 120: key = "f2"
        case 99: key = "f3"
        case 118: key = "f4"
        case 96: key = "f5"
        case 97: key = "f6"
        case 98: key = "f7"
        case 100: key = "f8"
        case 101: key = "f9"
        case 109: key = "f10"
        case 103: key = "f11"
        case 111: key = "f12"
        default:
            key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
        guard key.isEmpty == false else {
            NSSound.beep()
            return
        }
        let proposed = StacioShortcutBinding(key: key, modifiers: modifiers)
        onBindingChanged?(proposed)
        if binding.key == proposed.key && binding.modifierRawValue == proposed.modifierRawValue {
            window?.makeFirstResponder(nil)
        }
    }
}

@MainActor
public protocol AppSettingsCacheClearPresenting {
    func confirmClearCaches(summary: StacioCacheSummary, parentWindow: NSWindow?) -> Bool
    func presentClearCachesComplete(result: StacioCacheClearResult, parentWindow: NSWindow?)
    func presentClearCachesError(_ error: Error, parentWindow: NSWindow?)
}

public final class AppKitAppSettingsCacheClearPresenter: AppSettingsCacheClearPresenting {
    public init() {}

    public func confirmClearCaches(summary: StacioCacheSummary, parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Settings.clearCacheConfirmTitle
        alert.informativeText = L10n.Settings.clearCacheConfirmMessage(
            cacheSize: AppSettingsViewController.formatByteCount(summary.totalBytes),
            dirtyItemCount: summary.dirtyRemoteEditItemCount
        )
        alert.addButton(withTitle: L10n.Settings.clearCache)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func presentClearCachesComplete(result: StacioCacheClearResult, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.Settings.clearCacheCompletedTitle
        alert.informativeText = L10n.Settings.clearCacheCompletedMessage(
            cacheSize: AppSettingsViewController.formatByteCount(result.bytesCleared)
        )
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
    }

    public func presentClearCachesError(_ error: Error, parentWindow: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除缓存失败"
        alert.informativeText = RuntimeDiagnosticFormatter.userMessage(for: error)
        alert.addButton(withTitle: L10n.Common.ok)
        alert.runModal()
    }
}

@MainActor
public protocol AppSettingsAIConversationHistoryClearConfirming: AnyObject {
    func confirmClearAIConversationHistory(parentWindow: NSWindow?) -> Bool
}

public final class AppKitAIConversationHistoryClearConfirmation: AppSettingsAIConversationHistoryClearConfirming {
    public init() {}

    public func confirmClearAIConversationHistory(parentWindow: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Settings.clearAIConversationHistoryConfirmTitle
        alert.informativeText = L10n.Settings.clearAIConversationHistoryConfirmMessage
        alert.addButton(withTitle: L10n.Settings.clearAIConversationHistoryConfirmAction)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
public protocol AppSettingsUpdateChannelConfirming: AnyObject {
    func confirmUpdateChannelChange(
        from current: ProductOpsReleaseChannel,
        to proposed: ProductOpsReleaseChannel,
        parentWindow: NSWindow?
    ) -> Bool
}

@MainActor
public final class AppKitAppSettingsUpdateChannelConfirmation: AppSettingsUpdateChannelConfirming {
    public init() {}

    public func confirmUpdateChannelChange(
        from current: ProductOpsReleaseChannel,
        to proposed: ProductOpsReleaseChannel,
        parentWindow: NSWindow?
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.Settings.updateChannelConfirmTitle
        alert.informativeText = L10n.Settings.updateChannelConfirmMessage(
            from: current.displayName,
            to: proposed.displayName
        )
        alert.addButton(withTitle: L10n.Settings.updateChannelConfirmAction)
        alert.addButton(withTitle: L10n.Common.cancel)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
public final class AppSettingsWindowController: NSWindowController {
    private let settingsViewController: AppSettingsViewController

    public init(
        settingsStore: AppSettingsStore = .shared,
        cacheMaintenance: StacioCacheMaintaining = StacioCacheMaintenance(),
        cacheClearPresenter: AppSettingsCacheClearPresenting? = nil,
        aiAPIKeyStore: AIApiKeyStoring = KeychainAIApiKeyStore(),
        aiConnectionTester: AIAssistantConnectionTesting = DefaultAIAssistantConnectionTester(),
        aiModelCatalogLoader: AIModelCatalogLoading = DefaultAIModelCatalogLoader(),
        credentialCenterStore: CredentialCenterManaging? = CoreBridgeCredentialCenterStore.defaultStore(),
        conversationHistoryStore: AIAssistantConversationHistoryStoring? = CoreBridgeAIAssistantConversationHistoryStore.defaultStore(),
        aiConversationHistoryClearConfirmation: AppSettingsAIConversationHistoryClearConfirming? = nil,
        productOpsConfigurationStore: ProductOpsConfigurationStore = ProductOpsConfigurationStore(),
        updateChannelConfirmation: AppSettingsUpdateChannelConfirming? = nil,
        assistantSettingsValueStore: AssistantSettingsValueStore? = nil,
        assistantSettingsValueStoreProvider: @MainActor () -> AssistantSettingsValueStore? = {
            AssistantSettingsLiveStore.sharedIfAvailable()
        },
        assistantSettingsMutationCoordinator: AssistantSettingsMutationCoordinator? = nil
    ) {
        let liveAssistantSettingsValueStore = assistantSettingsValueStore
            ?? assistantSettingsValueStoreProvider()
        let liveAssistantSettingsMutationCoordinator = assistantSettingsMutationCoordinator
            ?? liveAssistantSettingsValueStore.flatMap { valueStore in
                try? AssistantSettingsMutationCoordinator.live(
                    valueStore: valueStore,
                    historyPruner: conversationHistoryStore as? AIAssistantConversationHistoryPruning
                )
            }
        settingsViewController = AppSettingsViewController(
            settingsStore: settingsStore,
            cacheMaintenance: cacheMaintenance,
            cacheClearPresenter: cacheClearPresenter ?? AppKitAppSettingsCacheClearPresenter(),
            aiAPIKeyStore: aiAPIKeyStore,
            aiConnectionTester: aiConnectionTester,
            aiModelCatalogLoader: aiModelCatalogLoader,
            credentialCenterStore: credentialCenterStore,
            conversationHistoryStore: conversationHistoryStore,
            aiConversationHistoryClearConfirmation: aiConversationHistoryClearConfirmation
                ?? AppKitAIConversationHistoryClearConfirmation(),
            productOpsConfigurationStore: productOpsConfigurationStore,
            updateChannelConfirmation: updateChannelConfirmation ?? AppKitAppSettingsUpdateChannelConfirmation(),
            assistantSettingsValueStore: liveAssistantSettingsValueStore,
            assistantSettingsMutationCoordinator: liveAssistantSettingsMutationCoordinator
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: AppSettingsLayout.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.Settings.title
        window.minSize = AppSettingsLayout.minWindowSize
        window.appearance = nil
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
        window.contentViewController = settingsViewController
        window.setContentSize(AppSettingsLayout.windowSize)
        window.center()
        super.init(window: window)
    }

    func injectLocalAgentSettingsDependenciesForTesting(
        _ dependencies: AppSettingsLocalAgentDependencies
    ) {
        settingsViewController.injectLocalAgentSettingsDependenciesForTesting(dependencies)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else {
            return
        }
        if window.frame.width < AppSettingsLayout.minWindowSize.width
            || window.frame.height < AppSettingsLayout.minWindowSize.height {
            window.setContentSize(AppSettingsLayout.windowSize)
            window.center()
        }
        if let contentView = window.contentView {
            let contentSize = window.contentRect(forFrameRect: window.frame).size
            let targetFrame = NSRect(
                x: 0,
                y: 0,
                width: max(AppSettingsLayout.minWindowSize.width, contentSize.width),
                height: max(AppSettingsLayout.minWindowSize.height, contentSize.height)
            )
            contentView.frame = targetFrame
            settingsViewController.view.frame = targetFrame
            settingsViewController.view.layoutSubtreeIfNeeded()
            contentView.layoutSubtreeIfNeeded()
        }
        settingsViewController.updateLocalAgentParentWindow(window)
    }
}

private enum AppSettingsLayout {
    static let windowSize = NSSize(width: 1040, height: 760)
    static let minWindowSize = NSSize(width: 980, height: 680)
    static let navigationWidth: CGFloat = 210
    static let navigationButtonWidth: CGFloat = 166
    static let navigationButtonHeight: CGFloat = 34
    static let navigationButtonFontSize: CGFloat = 15
    static let navigationButtonCornerRadius: CGFloat = 9
    static let navigationIconCanvasSize = NSSize(width: 28, height: 22)
    static let navigationIconDrawSize = NSSize(width: 18, height: 18)
    static let navigationIconLeadingInset: CGFloat = 7
    static let paneWidth: CGFloat = 700
    static let paneHorizontalInset: CGFloat = 30
    static let paneTopInset: CGFloat = 28
    static let groupWidth: CGFloat = paneWidth
    static let readableTextWidth: CGFloat = paneWidth
    static let settingsListCornerRadius: CGFloat = 12
    static let settingsListHorizontalInset: CGFloat = 14
    static let settingsListVerticalInset: CGFloat = 7
    static let settingsListContentWidth: CGFloat = groupWidth - (settingsListHorizontalInset * 2)
    static let settingsListSeparatorInset: CGFloat = 14
    static let labelColumnWidth: CGFloat = 218
    static let controlColumnWidth: CGFloat = 448
    static let formColumnSpacing: CGFloat = 16
    static let preferenceRowControlSpacing: CGFloat = 16
    static let preferenceRowMinHeight: CGFloat = 58
    static let settingsControlRowMinHeight: CGFloat = 46
    static let settingsNoteRowMinHeight: CGFloat = 34
    static let settingsSwitchSize = NSSize(width: 42, height: 26)
    static let settingsTextFieldHeight: CGFloat = 24
    static let fieldWidth: CGFloat = 320
    static let popupWidth: CGFloat = 280
    static let compactPopupWidth: CGFloat = 220
    static let segmentedWidth: CGFloat = 320
    static let mediumSegmentedWidth: CGFloat = 280
    static let compactFieldWidth: CGFloat = 55
    static let pathLabelWidth: CGFloat = 300
    static let terminalPreviewWidth: CGFloat = settingsListContentWidth
    static let terminalPreviewHeight: CGFloat = 184
    static let terminalThemeCardWidth: CGFloat = settingsListContentWidth
    static let terminalThemeCardHeight: CGFloat = 138
    static let terminalThemePreviewWidth: CGFloat = 280
    static let terminalThemePreviewHeight: CGFloat = 82
    static let ohMyZshPluginListHeight: CGFloat = 220
    static let ansiColorFieldWidth: CGFloat = 78
}

private final class AppSettingsFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private enum AppSettingsSection: Int, CaseIterable {
    case terminal
    case shortcuts
    case favoriteCommands
    case terminalTheme
    case ai
    case files
    case metrics
    case updates
    case security
    case ohMyZsh

    var identifier: String {
        switch self {
        case .terminal: return "terminal"
        case .shortcuts: return "shortcuts"
        case .favoriteCommands: return "favoriteCommands"
        case .terminalTheme: return "terminalTheme"
        case .ai: return "ai"
        case .files: return "files"
        case .metrics: return "metrics"
        case .updates: return "updates"
        case .security: return "security"
        case .ohMyZsh: return "ohMyZsh"
        }
    }

    var title: String {
        switch self {
        case .terminal: return L10n.Settings.terminal
        case .shortcuts: return L10n.Settings.shortcuts
        case .favoriteCommands: return L10n.Settings.favoriteCommands
        case .terminalTheme: return L10n.Settings.terminalTheme
        case .ai: return L10n.Settings.aiTroubleshootingAssistant
        case .files: return L10n.Settings.files
        case .metrics: return L10n.Settings.metrics
        case .updates: return L10n.Settings.updates
        case .security: return L10n.Settings.security
        case .ohMyZsh: return L10n.Settings.ohMyZsh
        }
    }

    var detail: String {
        switch self {
        case .terminal: return L10n.Settings.terminalDescription
        case .shortcuts: return L10n.Settings.shortcutsDescription
        case .favoriteCommands: return L10n.Settings.favoriteCommandsDescription
        case .terminalTheme: return L10n.Settings.terminalThemeDescription
        case .ai: return L10n.Settings.aiTroubleshootingAssistantDescription
        case .files: return L10n.Settings.filesDescription
        case .metrics: return L10n.Settings.metricsDescription
        case .updates: return L10n.Settings.updatesDescription
        case .security: return L10n.Settings.securityDescription
        case .ohMyZsh: return L10n.Settings.ohMyZshDescription
        }
    }

    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .shortcuts: return "keyboard"
        case .favoriteCommands: return "star"
        case .terminalTheme: return "paintpalette"
        case .ai: return "sparkles"
        case .files: return "folder"
        case .metrics: return "gauge.with.dots.needle.67percent"
        case .updates: return "arrow.triangle.2.circlepath"
        case .security: return "lock.shield"
        case .ohMyZsh: return "shippingbox"
        }
    }
}

@MainActor
struct AppSettingsLocalAgentDependencies {
    let configurationStore: LocalAgentConfigurationManaging
    let maintenanceJournal: LocalAgentMaintenanceProcessJournaling
    let detector: LocalAgentConfigurationDetecting
    let maintenancePresenter: LocalAgentMaintenancePresenting
    let websiteOpener: LocalAgentWebsiteOpening
    let controlState: () throws -> AgentConversationV2ControlState
    let updateParentWindow: (NSWindow?) -> Void
}

@MainActor
private final class LocalAgentSettingsAssembly {
    let viewController: LocalAgentSettingsViewController

    // The coordinator keeps presentation dependencies weak; the assembly owns
    // them for exactly as long as the Settings surface is alive.
    private let maintenancePresenter: LocalAgentMaintenancePresenting
    private let websiteOpener: LocalAgentWebsiteOpening
    private let settingsCoordinator: LocalAgentSettingsCoordinator
    private let configurationDeleteRouter: ConfigurationDeleteActionRouter
    private let parentWindowUpdater: (NSWindow?) -> Void

    init(
        parentWindow: NSWindow?,
        mutationCoordinator: AssistantSettingsMutationCoordinator,
        injectedDependencies: AppSettingsLocalAgentDependencies? = nil
    ) throws {
        let dependencies: AppSettingsLocalAgentDependencies
        if let injectedDependencies {
            dependencies = injectedDependencies
        } else {
            let paths = try StacioPaths()
            let control = try AgentConversationV2ControlCoordinator(
                databasePath: paths.applicationSupportDirectory
                    .appendingPathComponent("agent-control.sqlite3").path
            )
            let presenter = AppKitLocalAgentMaintenancePresenter(parentWindow: parentWindow)
            dependencies = AppSettingsLocalAgentDependencies(
                configurationStore: try LocalAgentConfigurationLiveStore.shared(),
                maintenanceJournal: try LocalAgentMaintenanceProcessJournalLiveStore.shared(),
                detector: LocalAgentConfigurationDetector(),
                maintenancePresenter: presenter,
                websiteOpener: AppKitLocalAgentWebsiteOpener(),
                controlState: { try control.controlState() },
                updateParentWindow: { [weak presenter] window in
                    presenter?.updateParentWindow(window)
                }
            )
        }
        let settingsCoordinator = LocalAgentSettingsCoordinator(
            detector: dependencies.detector,
            store: dependencies.configurationStore,
            maintenancePresenter: dependencies.maintenancePresenter,
            websiteOpener: dependencies.websiteOpener,
            maintenanceJournal: dependencies.maintenanceJournal,
            controlState: dependencies.controlState
        )
        let configurationDeleteRouter = ConfigurationDeleteActionRouter()
        try mutationCoordinator.registerLocalAgentOwners(
            settingsCoordinator,
            configurationDeleteRouter: configurationDeleteRouter
        )

        maintenancePresenter = dependencies.maintenancePresenter
        websiteOpener = dependencies.websiteOpener
        self.settingsCoordinator = settingsCoordinator
        self.configurationDeleteRouter = configurationDeleteRouter
        parentWindowUpdater = dependencies.updateParentWindow
        dependencies.updateParentWindow(parentWindow)
        viewController = LocalAgentSettingsViewController(
            coordinator: settingsCoordinator,
            actionAvailability: { [weak mutationCoordinator, weak settingsCoordinator] actionID in
                guard mutationCoordinator?.isActionAvailable(actionID) == true else {
                    return false
                }
                if actionID == "localAgent.logout" {
                    return settingsCoordinator?.isLogoutAvailable() == true
                }
                return true
            },
            actionHandler: { [weak mutationCoordinator] actionID, parameters, completion in
                guard let mutationCoordinator else {
                    completion(.failure(.missingOwner(actionID)))
                    return
                }
                mutationCoordinator.performAction(
                    actionID: actionID,
                    parameters: parameters,
                    completion: completion
                )
            }
        )
    }

    func updateParentWindow(_ window: NSWindow?) {
        parentWindowUpdater(window)
    }
}

private enum TerminalThemeGalleryItemID {
    static let systemAdaptive = "systemAdaptive"
}

@MainActor
private final class AppSettingsSwitchProxy: NSView {
    private let backingButton: NSButton
    private let nativeSwitch = NSSwitch()
    private var enabledObservation: NSKeyValueObservation?
    private var stateObservation: NSKeyValueObservation?

    init(backingButton: NSButton) {
        self.backingButton = backingButton
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        nativeSwitch.translatesAutoresizingMaskIntoConstraints = false
        nativeSwitch.state = backingButton.state
        nativeSwitch.target = self
        nativeSwitch.action = #selector(switchChanged(_:))
        nativeSwitch.toolTip = backingButton.title
        nativeSwitch.setAccessibilityIdentifier("\(backingButton.accessibilityIdentifier()).switch")

        backingButton.translatesAutoresizingMaskIntoConstraints = false
        backingButton.isHidden = true
        backingButton.alphaValue = 0

        addSubview(nativeSwitch)
        addSubview(backingButton)

        NSLayoutConstraint.activate([
            nativeSwitch.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativeSwitch.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativeSwitch.centerYAnchor.constraint(equalTo: centerYAnchor),
            nativeSwitch.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsSwitchSize.width),
            nativeSwitch.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsSwitchSize.height),

            backingButton.widthAnchor.constraint(equalToConstant: 0),
            backingButton.heightAnchor.constraint(equalToConstant: 0),
            backingButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            backingButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        enabledObservation = backingButton.observe(\NSButton.isEnabled, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncFromBackingButton() }
        }
        stateObservation = backingButton.observe(\NSButton.state, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncFromBackingButton() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        nativeSwitch.intrinsicContentSize
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        syncFromBackingButton()
    }

    private func syncFromBackingButton() {
        nativeSwitch.state = backingButton.state
        nativeSwitch.isEnabled = backingButton.isEnabled
    }

    @objc private func switchChanged(_ sender: NSSwitch) {
        backingButton.state = sender.state
        backingButton.sendAction(backingButton.action, to: backingButton.target)
        sender.state = backingButton.state
    }
}

private final class AppSettingsViewController: NSViewController, NSTextFieldDelegate, NSMenuDelegate {
    private let settingsStore: AppSettingsStore
    private let cacheMaintenance: StacioCacheMaintaining
    private let cacheClearPresenter: AppSettingsCacheClearPresenting
    private let aiAPIKeyStore: AIApiKeyStoring
    private let aiConnectionTester: AIAssistantConnectionTesting
    private let aiModelCatalogLoader: AIModelCatalogLoading
    private let credentialCenterStore: CredentialCenterManaging?
    private let conversationHistoryStore: AIAssistantConversationHistoryStoring?
    private let aiConversationHistoryClearConfirmation: AppSettingsAIConversationHistoryClearConfirming
    private let productOpsConfigurationStore: ProductOpsConfigurationStore
    private let updateChannelConfirmation: AppSettingsUpdateChannelConfirming
    private let assistantSettingsValueStore: AssistantSettingsValueStore?
    private let assistantSettingsMutationCoordinator: AssistantSettingsMutationCoordinator?
    private var localAgentSettingsDependencies: AppSettingsLocalAgentDependencies?
    private var aiSettingsViewController: AISettingsViewController?
    private var localAgentSettingsAssembly: LocalAgentSettingsAssembly?
    private let navigationView = NSVisualEffectView()
    private let contentHost = NSView()
    private var navigationButtons: [AppSettingsSection: NSButton] = [:]
    private var selectedSection: AppSettingsSection = .terminal
    private var favoriteCommandsWindowController: NSWindowController?

    private let fontSizeField = NSTextField()
    private let terminalFontFamilyPopup = NSPopUpButton()
    private let themeControl = NSSegmentedControl(
        labels: [L10n.Settings.system, L10n.Settings.light, L10n.Settings.dark, L10n.Settings.customTheme],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sessionTabIconModeControl = NSSegmentedControl(
        labels: [
            L10n.Settings.sessionTabIconDefault,
            L10n.Settings.sessionTabIconOperatingSystem
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let sessionSidebarShowRecentSessionsButton = NSButton(
        checkboxWithTitle: L10n.Settings.sessionSidebarShowRecentSessions,
        target: nil,
        action: nil
    )
    private let importTerminalThemeButton = NSButton(title: L10n.Settings.importTerminalTheme, target: nil, action: nil)
    private let terminalHighlightThemePopup = NSPopUpButton()
    private let customTerminalThemeLabel = NSTextField(labelWithString: "")
    private weak var terminalPreviewView: NSView?
    private weak var terminalPreviewTitleLabel: NSTextField?
    private weak var terminalPreviewSampleLabel: NSTextField?
    private weak var terminalPreviewPaletteView: NSStackView?
    private var terminalThemeCardButtons: [String: NSButton] = [:]
    private var terminalThemeCardCheckmarks: [String: NSImageView] = [:]
    private let terminalCloseConfirmationButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalCloseConfirmation,
        target: nil,
        action: nil
    )
    private let terminalSelectionAutoCopyButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalSelectionAutoCopy,
        target: nil,
        action: nil
    )
    private let terminalControlScrollZoomButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalControlScrollZoom,
        target: nil,
        action: nil
    )
    private let terminalScrollbackLinesField = NSTextField()
    private let terminalKeepAliveIntervalSecondsField = NSTextField()
    private let terminalX11DisplayField = NSTextField()
    private let terminalHardwareAccelerationButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalHardwareAcceleration,
        target: nil,
        action: nil
    )
    private let terminalWorkspacePaddingButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalWorkspacePadding,
        target: nil,
        action: nil
    )
    private let terminalLineNumbersButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalLineNumbers,
        target: nil,
        action: nil
    )
    private let terminalTimestampsButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalTimestamps,
        target: nil,
        action: nil
    )
    private let terminalTimestampMillisecondsButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalTimestampMilliseconds,
        target: nil,
        action: nil
    )
    private let terminalMultiLinePasteConfirmationButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalMultiLinePasteConfirmation,
        target: nil,
        action: nil
    )
    private let terminalPasteImageAsPathButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalPasteImageAsPath,
        target: nil,
        action: nil
    )
    private let terminalAltAsMetaButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalAltAsMeta,
        target: nil,
        action: nil
    )
    private let terminalMacIMECompatibilityButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalMacIMECompatibility,
        target: nil,
        action: nil
    )
    private let terminalCommandSuggestionButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalCommandSuggestion,
        target: nil,
        action: nil
    )
    private let terminalFavoriteCommandsButton = NSButton(
        title: "管理常用命令…",
        target: nil,
        action: nil
    )
    private let terminalCommandSuggestionHistoryMinLengthField = NSTextField()
    private let terminalCommandSuggestionHistoryMaxLengthField = NSTextField()
    private let terminalCommandSuggestionWordSeparatorsField = NSTextField()
    private let terminalDuplicateSessionCommandDelayMillisecondsField = NSTextField()
    private let terminalCommandCompletionNotificationButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalCommandCompletionNotification,
        target: nil,
        action: nil
    )
    private let terminalCommandCompletionNotificationThresholdSecondsField = NSTextField()
    private let terminalAutomaticReconnectButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalAutomaticReconnect,
        target: nil,
        action: nil
    )
    private let terminalAutomaticReconnectIntervalField = NSTextField()
    private let terminalAutomaticReconnectAttemptsField = NSTextField()
    private let terminalCursorStyleControl = NSSegmentedControl(
        labels: [
            L10n.Settings.terminalCursorBlock,
            L10n.Settings.terminalCursorBar,
            L10n.Settings.terminalCursorUnderline
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let terminalCursorBlinkButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalCursorBlink,
        target: nil,
        action: nil
    )
    private let terminalRightClickControl = NSSegmentedControl(
        labels: [
            L10n.Settings.terminalRightClickPaste,
            L10n.Settings.terminalRightClickMenu,
            L10n.Settings.terminalRightClickNone
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let terminalHighlightLevelControl = NSSegmentedControl(
        labels: [
            L10n.Settings.terminalHighlightOff,
            L10n.Settings.terminalHighlightANSI,
            L10n.Settings.terminalHighlightEnhanced
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let terminalRichHighlightingButton = NSButton(
        checkboxWithTitle: L10n.Settings.terminalRichHighlighting,
        target: nil,
        action: nil
    )
    private let aiProviderPopup = NSPopUpButton()
    private let aiBaseURLField = NSTextField()
    private let aiModelField = NSTextField()
    private let aiModelCatalogPopup = NSPopUpButton()
    private let aiRefreshModelsButton = NSButton(title: L10n.Settings.aiRefreshModels, target: nil, action: nil)
    private let aiAddCustomModelButton = NSButton(title: L10n.Settings.aiAddCustomModel, target: nil, action: nil)
    private let aiCustomModelListScrollView = NSScrollView()
    private let aiCustomModelListStack = NSStackView()
    private let aiReasoningEffortControl = NSSegmentedControl(
        labels: ["最小", "低", "中", "高"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let aiCompatibilityProtocolControl = NSSegmentedControl(
        labels: ["Chat", "Responses"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let aiModelCatalogStatusLabel = NSTextField(labelWithString: "")
    private let aiAPIKeyField = NSSecureTextField()
    private let aiMaxRetryCountField = NSTextField()
    private let aiRequestTimeoutSecondsField = NSTextField()
    private let aiUserAgentField = NSTextField()
    private let aiIncludeRecentTerminalTranscriptButton = NSButton(
        checkboxWithTitle: L10n.Settings.aiIncludeRecentTerminalTranscript,
        target: nil,
        action: nil
    )
    private let aiContextCharacterLimitField = NSTextField()
    private let aiTestConnectionButton = NSButton(title: L10n.Settings.aiTestConnection, target: nil, action: nil)
    private let aiConnectionStatusLabel = NSTextField(labelWithString: L10n.Settings.aiConnectionReady)
    private let aiClearConversationHistoryButton = NSButton(title: L10n.Settings.clearAIConversationHistory, target: nil, action: nil)
    private let aiConversationHistoryStatusLabel = NSTextField(labelWithString: "")
    private let aiRestoreLastConversationButton = NSButton(
        checkboxWithTitle: L10n.Settings.aiRestoreLastConversation,
        target: nil,
        action: nil
    )
    private let aiSendKeyModeControl = NSSegmentedControl(
        labels: [L10n.Settings.aiSendWithReturn, L10n.Settings.aiSendWithCommandReturn],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let aiTerminalOutputModeControl = NSSegmentedControl(
        labels: [
            L10n.Settings.aiTerminalOutputBounded,
            L10n.Settings.aiTerminalOutputSummary,
            L10n.Settings.aiTerminalOutputExcluded
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let aiAutoCompressContextButton = NSButton(
        checkboxWithTitle: L10n.Settings.aiAutoCompressContext,
        target: nil,
        action: nil
    )
    private let aiDefaultTerminalModeControl = NSSegmentedControl(
        labels: [
            L10n.Settings.aiRealTerminal,
            L10n.Settings.aiBackgroundTerminal,
            L10n.Settings.aiAskTerminalEveryTurn
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let aiMaxToolStepsField = NSTextField()
    private let aiMaxModelInvocationsField = NSTextField()
    private let aiMaxEffectiveMinutesField = NSTextField()
    private let aiEnabledToolLabel = NSTextField(labelWithString: L10n.Settings.aiTerminalCommandTool)
    private let aiHistoryRetentionDaysField = NSTextField()
    private let aiTerminalRecordingScopeControl = NSSegmentedControl(
        labels: [
            L10n.Settings.aiTerminalRecordingNone,
            L10n.Settings.aiTerminalRecordingBounded,
            L10n.Settings.aiTerminalRecordingFullWhenAudited
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let aiPrivacyStatusLabel = NSTextField(labelWithString: L10n.Settings.aiPrivacyStatus)
    private let aiSessionSettingsStatusLabel = NSTextField(labelWithString: "")
    private let aiContextSettingsStatusLabel = NSTextField(labelWithString: "")
    private let aiExecutionSettingsStatusLabel = NSTextField(labelWithString: "")
    private let aiSummaryProviderLabel = NSTextField(labelWithString: "")
    private let aiSummaryApprovalLabel = NSTextField(labelWithString: "")
    private let aiSummaryExecutionLabel = NSTextField(labelWithString: "")
    private let agentApprovalRiskMatrixLabel = NSTextField(labelWithString: "")
    private let securityApprovalRiskMatrixLabel = NSTextField(labelWithString: "")
    private let agentBridgeSocketLabel = NSTextField(labelWithString: "")
    private let copyAgentBridgeSocketButton = NSButton(title: L10n.Settings.copySocketPath, target: nil, action: nil)
    private let filesSummaryDirectoryFollowLabel = NSTextField(labelWithString: "")
    private let filesSummaryRemoteEditAutoDetectLabel = NSTextField(labelWithString: "")
    private let securitySummaryApprovalLabel = NSTextField(labelWithString: "")
    private let securitySummaryCredentialLabel = NSTextField(labelWithString: L10n.Settings.securityCredentialSummary)
    private let securitySummaryAuditLabel = NSTextField(labelWithString: L10n.Settings.securityAuditSummary)
    private let credentialCenterListPopup = NSPopUpButton()
    private let credentialCenterSummaryLabel = NSTextField(labelWithString: "")
    private let credentialCenterRefreshButton = NSButton(title: L10n.Settings.credentialCenterRefresh, target: nil, action: nil)
    private let credentialCenterDeleteButton = NSButton(title: L10n.Settings.credentialCenterDelete, target: nil, action: nil)
    private let credentialCenterNewLabelField = NSTextField()
    private let credentialCenterNewAccountField = NSTextField()
    private let credentialCenterNewSecretField = NSSecureTextField()
    private let credentialCenterAddPasswordButton = NSButton(title: L10n.Settings.credentialCenterAddPassword, target: nil, action: nil)
    private let credentialCenterAddPrivateKeyPassphraseButton = NSButton(
        title: L10n.Settings.credentialCenterAddPrivateKeyPassphrase,
        target: nil,
        action: nil
    )
    private let credentialCenterAddTokenButton = NSButton(title: L10n.Settings.credentialCenterAddToken, target: nil, action: nil)
    private var credentialCenterRecords: [CredentialRecord] = []
    private let applicationSupportPathLabel = NSTextField(labelWithString: "")
    private let databasePathLabel = NSTextField(labelWithString: "")
    private let logPathLabel = NSTextField(labelWithString: "")
    private let copyApplicationSupportPathButton = NSButton(title: L10n.Settings.copyPath, target: nil, action: nil)
    private let copyDatabasePathButton = NSButton(title: L10n.Settings.copyPath, target: nil, action: nil)
    private let copyLogPathButton = NSButton(title: L10n.Settings.copyPath, target: nil, action: nil)
    private let confirmationControl = NSSegmentedControl(
        labels: [
            L10n.Settings.allowAllCommands,
            L10n.Settings.allowLowRisk,
            L10n.Settings.allowReadOnly,
            L10n.Settings.requireEveryCommand
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let agentCommandAllowPatternsField = NSTextField()
    private let agentCommandDenyPatternsField = NSTextField()
    private let securityAgentCommandAllowPatternsField = NSTextField()
    private let securityAgentCommandDenyPatternsField = NSTextField()
    private let diagnosticsAuditExportLimitField = NSTextField()
    private let diagnosticsAppLogLineLimitField = NSTextField()
    private let diagnosticsIncludeAppLogsButton = NSButton(
        checkboxWithTitle: L10n.Settings.diagnosticsIncludeAppLogs,
        target: nil,
        action: nil
    )
    private let aiAutoRunProposedCommandsButton = NSButton(
        checkboxWithTitle: L10n.Settings.aiAutoRunProposedCommands,
        target: nil,
        action: nil
    )
    private let filesDirectoryFollowDefaultButton = NSButton(
        checkboxWithTitle: L10n.Settings.filesDirectoryFollowDefault,
        target: nil,
        action: nil
    )
    private let filesShowHiddenFilesByDefaultButton = NSButton(
        checkboxWithTitle: L10n.Settings.filesShowHiddenFilesByDefault,
        target: nil,
        action: nil
    )
    private let filesRemoteEditAutoDetectChangesButton = NSButton(
        checkboxWithTitle: L10n.Settings.filesRemoteEditAutoDetectChanges,
        target: nil,
        action: nil
    )
    private let filesTransferConflictPolicyPopup = NSPopUpButton()
    private let filesTransferQueueVisibleByDefaultButton = NSButton(
        checkboxWithTitle: L10n.Settings.filesTransferQueueVisibleByDefault,
        target: nil,
        action: nil
    )
    private let filesCacheSizeLabel = NSTextField(labelWithString: "")
    private let filesCacheHelpLabel = NSTextField(labelWithString: L10n.Settings.filesCacheHelp)
    private let filesClearCacheButton = NSButton(title: L10n.Settings.clearCache, target: nil, action: nil)
    private let metricsSummaryCollectionLabel = NSTextField(labelWithString: "")
    private let metricsSummaryDisplayLabel = NSTextField(labelWithString: "")
    private let deviceMetricsRefreshIntervalSecondsField = NSTextField()
    private let deviceMetricsDisplayLocationControl = NSSegmentedControl(
        labels: [
            L10n.Settings.deviceMetricsDisplayLocationFloating,
            L10n.Settings.deviceMetricsDisplayLocationTerminalBottom
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let deviceMetricsKeepLastSnapshotOnFailureButton = NSButton(
        checkboxWithTitle: L10n.Settings.deviceMetricsKeepLastSnapshotOnFailure,
        target: nil,
        action: nil
    )
    private let deviceMetricsShowNetworkSectionButton = NSButton(
        checkboxWithTitle: L10n.Settings.deviceMetricsShowNetworkSection,
        target: nil,
        action: nil
    )
    private let deviceMetricsShowDiskSectionButton = NSButton(
        checkboxWithTitle: L10n.Settings.deviceMetricsShowDiskSection,
        target: nil,
        action: nil
    )
    private let deviceMetricsDiskMountLimitField = NSTextField()
    private let deviceMetricsHideVirtualNetworkInterfacesButton = NSButton(
        checkboxWithTitle: L10n.Settings.deviceMetricsHideVirtualNetworkInterfaces,
        target: nil,
        action: nil
    )
    private let deviceMetricsHistorySampleCountField = NSTextField()
    private let deviceMetricsAlertEnabledButton = NSButton(
        checkboxWithTitle: L10n.Settings.deviceMetricsAlertEnabled,
        target: nil,
        action: nil
    )
    private let deviceMetricsCPUAlertThresholdPercentField = NSTextField()
    private let deviceMetricsMemoryAlertThresholdPercentField = NSTextField()
    private let deviceMetricsDiskAlertThresholdPercentField = NSTextField()
    private let deviceMetricsAlertConsecutiveRefreshCountField = NSTextField()
    private let securityConfirmationControl = NSSegmentedControl(
        labels: [
            L10n.Settings.allowAllCommands,
            L10n.Settings.allowLowRisk,
            L10n.Settings.allowReadOnly,
            L10n.Settings.requireEveryCommand
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let updateChannelControl = NSSegmentedControl(
        labels: ProductOpsReleaseChannel.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let updateChannelStatusLabel = NSTextField(labelWithString: "")
    // MARK: - Oh My Zsh 控件
    private let ohMyZshResourceStatusLabel = NSTextField(labelWithString: "")
    private let ohMyZshDownloadButton = NSButton(title: L10n.Settings.ohMyZshDownload, target: nil, action: nil)
    private let ohMyZshUninstallResourceButton = NSButton(title: L10n.Settings.ohMyZshUninstallResource, target: nil, action: nil)
    private let ohMyZshResourceSpinner = NSProgressIndicator()
    private let ohMyZshEnableButton = NSButton(
        checkboxWithTitle: L10n.Settings.ohMyZshEnable,
        target: nil,
        action: nil
    )
    private let ohMyZshThemePopup = NSPopUpButton()
    private let ohMyZshThemePreviewView = OhMyZshThemePreviewView()
    private let ohMyZshExtraZshrcField = NSTextField()
    private let ohMyZshPluginsScrollView = NSScrollView()
    private let ohMyZshPluginsStack = NSStackView()
    private var ohMyZshControlsConfigured = false
    private var ohMyZshResourcePollingTimer: Timer?
    private var ohMyZshDownloadRequestInFlight = false

    private var terminalControlsConfigured = false
    private var aiControlsConfigured = false
    private var filesControlsConfigured = false
    private var metricsControlsConfigured = false
    private var updateControlsConfigured = false
    private var securityControlsConfigured = false

    init(
        settingsStore: AppSettingsStore,
        cacheMaintenance: StacioCacheMaintaining,
        cacheClearPresenter: AppSettingsCacheClearPresenting,
        aiAPIKeyStore: AIApiKeyStoring,
        aiConnectionTester: AIAssistantConnectionTesting,
        aiModelCatalogLoader: AIModelCatalogLoading,
        credentialCenterStore: CredentialCenterManaging?,
        conversationHistoryStore: AIAssistantConversationHistoryStoring?,
        aiConversationHistoryClearConfirmation: AppSettingsAIConversationHistoryClearConfirming,
        productOpsConfigurationStore: ProductOpsConfigurationStore,
        updateChannelConfirmation: AppSettingsUpdateChannelConfirming,
        assistantSettingsValueStore: AssistantSettingsValueStore?,
        assistantSettingsMutationCoordinator: AssistantSettingsMutationCoordinator?
    ) {
        self.settingsStore = settingsStore
        self.cacheMaintenance = cacheMaintenance
        self.cacheClearPresenter = cacheClearPresenter
        self.aiAPIKeyStore = aiAPIKeyStore
        self.aiConnectionTester = aiConnectionTester
        self.aiModelCatalogLoader = aiModelCatalogLoader
        self.credentialCenterStore = credentialCenterStore
        self.conversationHistoryStore = conversationHistoryStore
        self.aiConversationHistoryClearConfirmation = aiConversationHistoryClearConfirmation
        self.productOpsConfigurationStore = productOpsConfigurationStore
        self.updateChannelConfirmation = updateChannelConfirmation
        self.assistantSettingsValueStore = assistantSettingsValueStore
        self.assistantSettingsMutationCoordinator = assistantSettingsMutationCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    func injectLocalAgentSettingsDependenciesForTesting(
        _ dependencies: AppSettingsLocalAgentDependencies
    ) {
        precondition(
            localAgentSettingsAssembly == nil && aiSettingsViewController == nil,
            "Local Agent dependencies must be injected before the AI Settings surface is created"
        )
        localAgentSettingsDependencies = dependencies
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        preferredContentSize = AppSettingsLayout.windowSize
        let root = AppSettingsRootView(frame: NSRect(origin: .zero, size: AppSettingsLayout.windowSize))
        root.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(root, color: NSColor.windowBackgroundColor)
        root.setAccessibilityIdentifier("Stacio.Settings.root")
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.minWindowSize.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.minWindowSize.height)
        ])

        configureNavigationView()
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(contentHost, color: NSColor.windowBackgroundColor)
        contentHost.setAccessibilityIdentifier("Stacio.Settings.content")

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        root.addSubview(navigationView)
        root.addSubview(separator)
        root.addSubview(contentHost)
        NSLayoutConstraint.activate([
            navigationView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navigationView.topAnchor.constraint(equalTo: root.topAnchor),
            navigationView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            navigationView.widthAnchor.constraint(equalToConstant: AppSettingsLayout.navigationWidth),

            separator.leadingAnchor.constraint(equalTo: navigationView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            contentHost.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
        root.onEffectiveAppearanceChange = { [weak self] in
            self?.refreshTerminalPreview()
        }
        select(section: .terminal)
    }

    private func configureNavigationView() {
        navigationView.translatesAutoresizingMaskIntoConstraints = false
        navigationView.material = .sidebar
        navigationView.blendingMode = .behindWindow
        navigationView.state = .active
        navigationView.setAccessibilityIdentifier("Stacio.Settings.navigation")

        let title = NSTextField(labelWithString: L10n.Settings.title)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(18, after: title)

        for section in AppSettingsSection.allCases {
            let button = makeNavigationButton(for: section)
            navigationButtons[section] = button
            stack.addArrangedSubview(button)
        }

        navigationView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: navigationView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: navigationView.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: navigationView.topAnchor, constant: 24)
        ])
    }

    private func makeNavigationButton(for section: AppSettingsSection) -> NSButton {
        let image = makeNavigationIcon(for: section)
        let button = NSButton(title: section.title, image: image, target: self, action: #selector(navigationChanged(_:)))
        button.tag = section.rawValue
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.setButtonType(.toggle)
        button.wantsLayer = true
        button.layer?.cornerRadius = AppSettingsLayout.navigationButtonCornerRadius
        button.layer?.cornerCurve = .continuous
        updateNavigationButtonAppearance(button, selected: false)
        button.setAccessibilityIdentifier("Stacio.Settings.nav.\(section.identifier)")
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: AppSettingsLayout.navigationButtonWidth),
            button.heightAnchor.constraint(equalToConstant: AppSettingsLayout.navigationButtonHeight)
        ])
        return button
    }

    private func makeNavigationIcon(for section: AppSettingsSection) -> NSImage {
        let baseImage = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
            ?? NSImage(size: AppSettingsLayout.navigationIconDrawSize)
        let configuredImage = baseImage.withSymbolConfiguration(
            .init(pointSize: AppSettingsLayout.navigationIconDrawSize.height, weight: .regular)
        ) ?? baseImage
        let canvasSize = AppSettingsLayout.navigationIconCanvasSize
        let drawSize = AppSettingsLayout.navigationIconDrawSize
        let image = NSImage(size: canvasSize, flipped: false) { _ in
            let drawRect = NSRect(
                x: AppSettingsLayout.navigationIconLeadingInset,
                y: (canvasSize.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            configuredImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = section.title
        return image
    }

    @objc private func navigationChanged(_ sender: NSButton) {
        guard let section = AppSettingsSection(rawValue: sender.tag) else {
            return
        }
        select(section: section)
    }

    private func select(section: AppSettingsSection) {
        selectedSection = section
        for (candidate, button) in navigationButtons {
            let selected = candidate == section
            button.state = selected ? .on : .off
            updateNavigationButtonAppearance(button, selected: selected)
        }

        children.forEach { $0.removeFromParent() }
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let pane = makePane(for: section)
        pane.translatesAutoresizingMaskIntoConstraints = false
        if section == .ai {
            contentHost.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                pane.topAnchor.constraint(equalTo: contentHost.topAnchor),
                pane.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
            ])
            contentHost.layoutSubtreeIfNeeded()
            return
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityIdentifier("Stacio.Settings.contentScrollView")

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.setAccessibilityIdentifier("Stacio.Settings.scrollDocument")
        documentView.addSubview(pane)
        scrollView.documentView = documentView
        contentHost.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),

            pane.widthAnchor.constraint(equalToConstant: AppSettingsLayout.paneWidth),
            pane.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: AppSettingsLayout.paneHorizontalInset),
            pane.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -AppSettingsLayout.paneHorizontalInset),
            pane.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            pane.topAnchor.constraint(equalTo: documentView.topAnchor, constant: AppSettingsLayout.paneTopInset),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -AppSettingsLayout.paneTopInset)
        ])
        contentHost.layoutSubtreeIfNeeded()
    }

    private func updateNavigationButtonAppearance(_ button: NSButton, selected: Bool) {
        button.wantsLayer = true
        button.layer?.cornerRadius = AppSettingsLayout.navigationButtonCornerRadius
        button.layer?.cornerCurve = .continuous
        button.layer?.masksToBounds = false
        button.layer?.borderWidth = 0
        button.layer?.borderColor = nil
        button.layer?.backgroundColor = selected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).cgColor
            : nil
        button.contentTintColor = selected
            ? StacioDesignSystem.theme.primaryTextColor
            : StacioDesignSystem.theme.secondaryTextColor
        button.font = .systemFont(
            ofSize: AppSettingsLayout.navigationButtonFontSize,
            weight: selected ? .medium : .regular
        )
    }

    private func makePane(for section: AppSettingsSection) -> NSView {
        switch section {
        case .terminal:
            return makeTerminalPane()
        case .shortcuts:
            return makeShortcutsPane()
        case .favoriteCommands:
            return makeFavoriteCommandsPane()
        case .terminalTheme:
            return makeTerminalThemePane()
        case .ai:
            return makeAIPane()
        case .files:
            return makeFilesPane()
        case .metrics:
            return makeMetricsPane()
        case .updates:
            return makeUpdatesPane()
        case .security:
            return makeSecurityPane()
        case .ohMyZsh:
            return makeOhMyZshPane()
        }
    }

    private func makeShortcutsPane() -> NSView {
        let stack = makePaneStack(section: .shortcuts)
        let store = StacioShortcutStore.shared
        let rows = StacioShortcutAction.allCases.map { makeShortcutRow(for: $0, store: store) }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 1
        list.translatesAutoresizingMaskIntoConstraints = false
        list.setAccessibilityIdentifier("Stacio.Settings.shortcutsList")
        stack.addArrangedSubview(list)
        NSLayoutConstraint.activate([
            list.widthAnchor.constraint(equalToConstant: AppSettingsLayout.paneWidth)
        ])
        return stack
    }

    private func makeShortcutRow(for action: StacioShortcutAction, store: StacioShortcutStore) -> NSView {
        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        let detail = NSTextField(labelWithString: action.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = StacioDesignSystem.theme.secondaryTextColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let recorder = StacioShortcutRecorderField()
        recorder.binding = store.binding(for: action)
        recorder.setAccessibilityIdentifier("Stacio.Settings.shortcut.\(action.rawValue)")
        let conflict = NSTextField(labelWithString: "")
        conflict.font = .systemFont(ofSize: 11)
        conflict.textColor = .systemRed
        conflict.maximumNumberOfLines = 1
        conflict.lineBreakMode = .byTruncatingTail
        let reset = NSButton(title: "恢复默认", target: nil, action: nil)
        reset.bezelStyle = .inline
        reset.target = self
        reset.action = #selector(resetShortcut(_:))
        reset.tag = StacioShortcutAction.allCases.firstIndex(of: action) ?? 0

        recorder.onBindingChanged = { [weak recorder, weak conflict] binding in
            let result = store.set(binding, for: action)
            if let message = result.message {
                conflict?.stringValue = message
                recorder?.binding = store.binding(for: action)
            } else {
                conflict?.stringValue = ""
                recorder?.binding = binding
            }
        }
        let row = NSStackView(views: [labels, NSView(), recorder, conflict, reset])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        row.layer?.cornerRadius = 8
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recorder.widthAnchor.constraint(equalToConstant: 100).isActive = true
        conflict.widthAnchor.constraint(equalToConstant: 145).isActive = true
        reset.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return row
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard StacioShortcutAction.allCases.indices.contains(sender.tag)
        else { return }
        let action = StacioShortcutAction.allCases[sender.tag]
        StacioShortcutStore.shared.reset(action)
        select(section: .shortcuts)
    }

    private func makeTerminalPane() -> NSView {
        configureTerminalControls()
        let stack = makePaneStack(section: .terminal)
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.sessionSidebarGroupTitle,
            detail: L10n.Settings.sessionSidebarGroupDescription,
            identifier: "Stacio.Settings.group.sessionSidebar",
            content: [
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.sessionSidebarShowRecentSessions,
                    detail: L10n.Settings.sessionSidebarShowRecentSessionsHelp,
                    button: sessionSidebarShowRecentSessionsButton,
                    identifier: "sessionSidebarShowRecentSessions"
                )
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.terminalGeneralGroupTitle,
            detail: L10n.Settings.terminalGeneralGroupDescription,
            identifier: "Stacio.Settings.group.terminalGeneral",
            content: [
                makeSettingsPreferenceRow(
                    title: L10n.Settings.terminalScrollbackLines,
                    detail: L10n.Settings.terminalScrollbackLinesHelp,
                    control: terminalScrollbackLinesField,
                    identifier: "terminalScrollbackLines"
                ),
                makeSettingsPreferenceRow(
                    title: L10n.Settings.terminalKeepAliveInterval,
                    detail: L10n.Settings.terminalKeepAliveIntervalHelp,
                    control: terminalKeepAliveIntervalSecondsField,
                    identifier: "terminalKeepAliveIntervalSeconds"
                ),
                makeSettingsPreferenceRow(
                    title: L10n.Settings.terminalX11Display,
                    detail: L10n.Settings.terminalX11DisplayHelp,
                    control: terminalX11DisplayField,
                    identifier: "terminalX11Display"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalHardwareAcceleration,
                    detail: L10n.Settings.terminalHardwareAccelerationHelp,
                    button: terminalHardwareAccelerationButton,
                    identifier: "terminalHardwareAcceleration"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalWorkspacePadding,
                    detail: L10n.Settings.terminalWorkspacePaddingHelp,
                    button: terminalWorkspacePaddingButton,
                    identifier: "terminalWorkspacePadding"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalLineNumbers,
                    detail: L10n.Settings.terminalLineNumbersHelp,
                    button: terminalLineNumbersButton,
                    identifier: "terminalLineNumbers"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalTimestamps,
                    detail: L10n.Settings.terminalTimestampsHelp,
                    button: terminalTimestampsButton,
                    identifier: "terminalTimestamps"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalTimestampMilliseconds,
                    detail: L10n.Settings.terminalTimestampMillisecondsHelp,
                    button: terminalTimestampMillisecondsButton,
                    identifier: "terminalTimestampMilliseconds"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalMultiLinePasteConfirmation,
                    detail: L10n.Settings.terminalMultiLinePasteConfirmationHelp,
                    button: terminalMultiLinePasteConfirmationButton,
                    identifier: "terminalMultiLinePasteConfirmation"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalPasteImageAsPath,
                    detail: L10n.Settings.terminalPasteImageAsPathHelp,
                    button: terminalPasteImageAsPathButton,
                    identifier: "terminalPasteImageAsPath"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalAltAsMeta,
                    detail: L10n.Settings.terminalAltAsMetaHelp,
                    button: terminalAltAsMetaButton,
                    identifier: "terminalAltAsMeta"
                ),
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.terminalMacIMECompatibility,
                    detail: L10n.Settings.terminalMacIMECompatibilityHelp,
                    button: terminalMacIMECompatibilityButton,
                    identifier: "terminalMacIMECompatibility"
                )
            ]
        ))
        let terminalIdentityForm = makeForm(rows: [
            (L10n.Settings.terminalFontFamily, terminalFontFamilyPopup),
            (L10n.Settings.fontSize, fontSizeField),
            (L10n.Settings.sessionTabIconMode, sessionTabIconModeControl)
        ])
        let terminalHighlightForm = makeForm(rows: [
            (L10n.Settings.terminalHighlightLevel, terminalHighlightLevelControl)
        ])
        let terminalCursorForm = makeForm(rows: [
            (L10n.Settings.terminalCursorStyle, terminalCursorStyleControl)
        ])
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.terminalAppearanceGroupTitle,
            detail: L10n.Settings.terminalAppearanceGroupDescription,
            identifier: "Stacio.Settings.group.terminalAppearance",
            content: [
                makeSettingsDetailBlock([
                    terminalIdentityForm,
                    makeControlColumnHelpLabel(
                        L10n.Settings.sessionTabIconModeHelp,
                        identifier: "Stacio.Settings.sessionTabIconModeHelp"
                    )
                ]),
                makeSettingsDetailBlock([
                    terminalHighlightForm,
                    makeControlColumnHelpLabel(
                        L10n.Settings.terminalHighlightHelp,
                        identifier: "Stacio.Settings.terminalHighlightHelp"
                    )
                ]),
                makeSettingsDetailBlock([
                    makeControlColumnRow(terminalRichHighlightingButton),
                    makeControlColumnHelpLabel(
                        L10n.Settings.terminalRichHighlightingHelp,
                        identifier: "Stacio.Settings.terminalRichHighlightingHelp"
                    )
                ]),
                terminalCursorForm,
                makeControlColumnRow(terminalCursorBlinkButton),
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.terminalCommandInputGroupTitle,
            detail: L10n.Settings.terminalCommandInputGroupDescription,
            identifier: "Stacio.Settings.group.terminalCommandInput",
            content: [
                makeSettingsDetailBlock([
                    makeControlColumnRow(terminalCommandSuggestionButton),
                    makeControlColumnHelpLabel(
                        L10n.Settings.terminalCommandSuggestionHelp,
                        identifier: "Stacio.Settings.terminalCommandSuggestionHelp"
                    )
                ]),
                makeForm(rows: [
                    (
                        L10n.Settings.terminalCommandSuggestionHistoryMinLength,
                        terminalCommandSuggestionHistoryMinLengthField
                    ),
                    (
                        L10n.Settings.terminalCommandSuggestionHistoryMaxLength,
                        terminalCommandSuggestionHistoryMaxLengthField
                    ),
                    (
                        L10n.Settings.terminalCommandSuggestionWordSeparators,
                        terminalCommandSuggestionWordSeparatorsField
                    ),
                    (
                        L10n.Settings.terminalDuplicateSessionCommandDelay,
                        terminalDuplicateSessionCommandDelayMillisecondsField
                    )
                ]),
                makeSettingsPreferenceRow(
                    title: "全局常用命令",
                    detail: "管理跨 SSH 与本地终端复用的命令。命令以明文保存在本机设置中，请勿保存密码、令牌等敏感内容。",
                    control: terminalFavoriteCommandsButton,
                    identifier: "terminalFavoriteCommands"
                )
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.terminalBehaviorGroupTitle,
            detail: L10n.Settings.terminalBehaviorGroupDescription,
            identifier: "Stacio.Settings.group.terminalBehavior",
            content: [
                makeControlColumnRow(terminalCloseConfirmationButton),
                makeControlColumnRow(terminalSelectionAutoCopyButton),
                makeForm(rows: [(L10n.Settings.terminalRightClickBehavior, terminalRightClickControl)]),
                makeControlColumnRow(terminalControlScrollZoomButton),
                makeControlColumnRow(terminalCommandCompletionNotificationButton),
                makeForm(rows: [
                    (
                        L10n.Settings.terminalCommandCompletionNotificationThreshold,
                        terminalCommandCompletionNotificationThresholdSecondsField
                    )
                ]),
                makeControlColumnRow(terminalAutomaticReconnectButton),
                makeForm(rows: [
                    (L10n.Settings.terminalAutomaticReconnectInterval, terminalAutomaticReconnectIntervalField),
                    (L10n.Settings.terminalAutomaticReconnectAttempts, terminalAutomaticReconnectAttemptsField)
                ]),
                makeControlColumnHelpLabel(L10n.Settings.terminalAutomaticReconnectHelp)
            ]
        ))
        return stack
    }

    private func makeFavoriteCommandsPane() -> NSView {
        let stack = makePaneStack(section: .favoriteCommands)
        let manager = TerminalFavoriteCommandManagerViewController()
        addChild(manager)
        manager.loadViewIfNeeded()
        let managerView = manager.view
        managerView.translatesAutoresizingMaskIntoConstraints = false
        managerView.setAccessibilityIdentifier("Stacio.Settings.favoriteCommandsManager")
        stack.addArrangedSubview(managerView)
        NSLayoutConstraint.activate([
            managerView.widthAnchor.constraint(equalToConstant: AppSettingsLayout.paneWidth),
            managerView.heightAnchor.constraint(equalToConstant: 360)
        ])
        return stack
    }

    private func makeTerminalThemePane() -> NSView {
        configureTerminalControls()
        let stack = makePaneStack(section: .terminalTheme)
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.terminalThemeModeGroupTitle,
            detail: L10n.Settings.terminalThemeModeGroupDescription,
            identifier: "Stacio.Settings.group.terminalThemeMode",
            content: [
                makeForm(rows: [(L10n.Settings.theme, themeControl)]),
                makeTerminalPreview()
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.terminalThemeLibraryGroupTitle,
            detail: L10n.Settings.terminalThemeLibraryGroupDescription,
            identifier: "Stacio.Settings.group.terminalThemeLibrary",
            content: [
                makeForm(rows: [(L10n.Settings.terminalHighlightTheme, terminalHighlightThemePopup)]),
                makeTerminalThemeGallery(),
                makeSettingsDetailBlock([
                    makeControlColumnRow(makeTerminalThemeImportRow()),
                    makeControlColumnHelpLabel(
                        L10n.Settings.terminalThemeImportHint,
                        identifier: "Stacio.Settings.terminalThemeImportHint"
                    )
                ])
            ]
        ))
        return stack
    }

    private func makeAIPane() -> NSView {
        if let aiSettingsViewController {
            addChild(aiSettingsViewController)
            localAgentSettingsAssembly?.updateParentWindow(view.window)
            return aiSettingsViewController.view
        }
        configureAIControls()
        let providerManager = AIProviderManagementViewController(
            settingsStore: settingsStore,
            mutationCoordinator: makeAIProviderMutationCoordinator(),
            modelCatalogLoader: aiModelCatalogLoader,
            connectionTester: aiConnectionTester
        )
        let localAgentView = makeLocalAgentSettingsView()
        let controller = AISettingsViewController(
            providerManager: providerManager,
            localAgentView: localAgentView,
            contextView: makeAIContextTab(),
            executionPermissionsView: makeAIExecutionPermissionsTab(),
            historyView: makeAIHistoryTab(),
            addProviderSheetFactory: { [settingsStore, aiModelCatalogLoader, aiAPIKeyStore] in
                AddAIProviderSheetController(
                    mutationCoordinator: Self.makeAIProviderMutationCoordinator(
                        settingsStore: settingsStore,
                        apiKeyStore: aiAPIKeyStore
                    ),
                    modelCatalogLoader: aiModelCatalogLoader
                )
            }
        )
        aiSettingsViewController = controller
        addChild(controller)
        return controller.view
    }

    /// Production assembly for the CLI Coding Plan surface. The Local Agent
    /// editor owns the same durable stores and Action Coordinator used by the
    /// rest of Assistant Settings; a failure leaves a visible fail-closed
    /// explanation instead of a partially functional form.
    private func makeLocalAgentSettingsView() -> NSView {
        if let localAgentSettingsAssembly {
            localAgentSettingsAssembly.updateParentWindow(view.window)
            return localAgentSettingsAssembly.viewController.view
        }
        guard let assistantSettingsMutationCoordinator else {
            localAgentSettingsAssembly = nil
            return makeLocalAgentUnavailableView(
                reason: "排查助手设置存储不可用，无法安全启用本地 Agent 操作。"
            )
        }
        do {
            let assembly = try LocalAgentSettingsAssembly(
                parentWindow: view.window,
                mutationCoordinator: assistantSettingsMutationCoordinator,
                injectedDependencies: localAgentSettingsDependencies
            )
            localAgentSettingsAssembly = assembly
            return assembly.viewController.view
        } catch {
            localAgentSettingsAssembly = nil
            return makeLocalAgentUnavailableView(
                reason: "本地 Agent 配置不可用，相关操作已关闭。"
            )
        }
    }

    private func makeLocalAgentUnavailableView(reason: String) -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityIdentifier("Stacio.Settings.localAgent.unavailable")
        let title = NSTextField(labelWithString: "本地 Agent 配置不可用")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        let detail = NSTextField(wrappingLabelWithString: reason)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = StacioDesignSystem.theme.secondaryTextColor
        detail.maximumNumberOfLines = 0
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

    func updateLocalAgentParentWindow(_ window: NSWindow?) {
        localAgentSettingsAssembly?.updateParentWindow(window)
    }

    private func makeAIContextTab() -> NSView {
        let stack = makePlainAIStack()
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.aiSessionGroupTitle,
            detail: L10n.Settings.aiSessionGroupDescription,
            identifier: "Stacio.Settings.group.aiSession",
            content: [
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.aiRestoreLastConversation,
                    detail: L10n.Settings.aiRestoreLastConversationHelp,
                    button: aiRestoreLastConversationButton,
                    identifier: "aiRestoreLastConversation"
                ),
                makeForm(rows: [(L10n.Settings.aiSendKeyMode, aiSendKeyModeControl)]),
                makeControlColumnHelpLabel(
                    L10n.Settings.aiSendKeyModeHelp,
                    identifier: "Stacio.Settings.aiSendKeyModeHelp"
                ),
                makeSettingsNoteRow(aiSessionSettingsStatusLabel)
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.aiContextGroupTitle,
            detail: L10n.Settings.aiContextGroupDescription,
            identifier: "Stacio.Settings.group.aiContext",
            content: [
                makeSettingsDetailBlock([
                    makeForm(rows: [(L10n.Settings.aiTerminalOutputMode, aiTerminalOutputModeControl)]),
                    makeSettingsPreferenceToggleRow(
                        title: L10n.Settings.aiAutoCompressContext,
                        detail: L10n.Settings.aiAutoCompressContextHelp,
                        button: aiAutoCompressContextButton,
                        identifier: "aiAutoCompressContext"
                    ),
                    makeSettingsNoteRow(aiContextSettingsStatusLabel),
                    makeControlColumnHelpLabel(
                        L10n.Settings.aiContextHelp,
                        identifier: "Stacio.Settings.aiContextHelp"
                    )
                ])
            ]
        ))
        return stack
    }

    private func makeAIExecutionPermissionsTab() -> NSView {
        let stack = makePlainAIStack()
        let executionForm = makeForm(rows: [
            (L10n.Settings.confirmationPolicy, confirmationControl),
            (L10n.Settings.aiDefaultTerminalMode, aiDefaultTerminalModeControl),
            (L10n.Settings.agentCommandAllowPatterns, agentCommandAllowPatternsField),
            (L10n.Settings.agentCommandDenyPatterns, agentCommandDenyPatternsField)
        ])
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.aiExecutionGroupTitle,
            detail: L10n.Settings.aiExecutionGroupDescription,
            identifier: "Stacio.Settings.group.aiExecution",
            content: [
                makeSettingsDetailBlock([
                    executionForm,
                    makeControlColumnHelpLabel(
                        L10n.Settings.agentCommandPatternHelp,
                        identifier: "Stacio.Settings.agentCommandPatternHelp"
                    )
                ]),
                makeApprovalRiskMatrixLabel(
                    agentApprovalRiskMatrixLabel,
                    identifier: "Stacio.Settings.agentApprovalRiskMatrix"
                ),
                makeSettingsDetailBlock([
                    makeControlColumnRow(aiAutoRunProposedCommandsButton),
                    makeControlColumnHelpLabel(
                        L10n.Settings.aiExecutionHelp,
                        identifier: "Stacio.Settings.aiExecutionHelp"
                    )
                ])
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.aiTaskLimitsGroupTitle,
            detail: L10n.Settings.aiTaskLimitsGroupDescription,
            identifier: "Stacio.Settings.group.aiTaskLimits",
            content: [
                makeForm(rows: [
                    (L10n.Settings.aiMaxToolSteps, aiMaxToolStepsField),
                    (L10n.Settings.aiMaxModelInvocations, aiMaxModelInvocationsField),
                    (L10n.Settings.aiMaxEffectiveMinutes, aiMaxEffectiveMinutesField),
                    (L10n.Settings.aiEnabledTool, aiEnabledToolLabel)
                ]),
                makeControlColumnHelpLabel(
                    L10n.Settings.aiTerminalCommandToolHelp,
                    identifier: "Stacio.Settings.aiTerminalCommandToolHelp"
                ),
                makeSettingsNoteRow(aiExecutionSettingsStatusLabel)
            ]
        ))
        stack.addArrangedSubview(makeAgentBridgeGroup())
        return stack
    }

    private func makeAIHistoryTab() -> NSView {
        let stack = makePlainAIStack()
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.aiConversationHistoryGroupTitle,
            detail: L10n.Settings.aiConversationHistoryGroupDescription,
            identifier: "Stacio.Settings.group.aiConversationHistory",
            content: [
                makeSettingsDetailBlock([
                    makeForm(rows: [(L10n.Settings.aiHistoryRetentionDays, aiHistoryRetentionDaysField)]),
                    makeControlColumnHelpLabel(
                        L10n.Settings.aiHistoryRetentionHelp,
                        identifier: "Stacio.Settings.aiHistoryRetentionHelp"
                    ),
                    makeControlColumnRow(aiClearConversationHistoryButton),
                    makeSettingsNoteRow(aiConversationHistoryStatusLabel),
                    makeControlColumnHelpLabel(
                        L10n.Settings.aiConversationHistoryHelp,
                        identifier: "Stacio.Settings.aiConversationHistoryHelp"
                    )
                ])
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.aiPrivacyGroupTitle,
            detail: L10n.Settings.aiPrivacyGroupDescription,
            identifier: "Stacio.Settings.group.aiPrivacy",
            content: [
                makeSettingsDetailBlock([
                    makeForm(rows: [
                        (L10n.Settings.aiTerminalRecordingScope, aiTerminalRecordingScopeControl)
                    ]),
                    makeControlColumnHelpLabel(
                        L10n.Settings.aiTerminalRecordingScopeHelp,
                        identifier: "Stacio.Settings.aiTerminalRecordingScopeHelp"
                    ),
                    makeSettingsNoteRow(aiPrivacyStatusLabel)
                ])
            ]
        ))
        return stack
    }

    private func makePlainAIStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: AppSettingsLayout.paneWidth)
        ])
        return stack
    }

    private func makeAIProviderMutationCoordinator() -> AIProviderMutationCoordinating {
        Self.makeAIProviderMutationCoordinator(
            settingsStore: settingsStore,
            apiKeyStore: aiAPIKeyStore
        )
    }

    private static func makeAIProviderMutationCoordinator(
        settingsStore: AppSettingsStore,
        apiKeyStore: AIApiKeyStoring
    ) -> AIProviderMutationCoordinating {
        if let keyStore = apiKeyStore as? (AIApiKeyStoring & LegacyAIApiKeyReading) {
            return AIProviderConfigurationCoordinator(
                settingsStore: settingsStore,
                keyStore: keyStore
            )
        }
        return AIProviderConfigurationCoordinator(
            settingsStore: settingsStore,
            keyStore: NonMigratingAIApiKeyStoreAdapter(apiKeyStore)
        )
    }

    private func makeFilesPane() -> NSView {
        configureFilesControls()
        let stack = makePaneStack(section: .files)
        stack.addArrangedSubview(makeFilesStatusOverview())
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.filesNavigationGroupTitle,
            detail: L10n.Settings.filesNavigationGroupDescription,
            identifier: "Stacio.Settings.group.filesNavigation",
            content: [
                makeFilesToggleSetting(
                    button: filesDirectoryFollowDefaultButton,
                    help: L10n.Settings.filesDirectoryFollowHelp
                ),
                makeFilesToggleSetting(
                    button: filesShowHiddenFilesByDefaultButton,
                    help: L10n.Settings.filesShowHiddenFilesHelp
                ),
                makeFilesToggleSetting(
                    button: filesRemoteEditAutoDetectChangesButton,
                    help: L10n.Settings.filesRemoteEditAutoDetectHelp
                ),
                makeFilesConflictPolicyRow(),
                makeFilesToggleSetting(
                    button: filesTransferQueueVisibleByDefaultButton,
                    help: L10n.Settings.filesTransferPolicyHelp,
                    helpIdentifier: "Stacio.Settings.filesTransferPolicyHelp"
                )
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.filesCacheGroupTitle,
            detail: L10n.Settings.filesCacheGroupDescription,
            identifier: "Stacio.Settings.group.filesCache",
            content: [
                makeSettingsStatusActionRow(label: filesCacheSizeLabel, action: filesClearCacheButton),
                makeSettingsNoteRow(filesCacheHelpLabel)
            ]
        ))
        return stack
    }

    private func makeMetricsPane() -> NSView {
        configureMetricsControls()
        let stack = makePaneStack(section: .metrics)
        stack.addArrangedSubview(makeMetricsStatusOverview())
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.metricsCollectionGroupTitle,
            detail: L10n.Settings.metricsCollectionGroupDescription,
            identifier: "Stacio.Settings.group.metricsCollection",
            content: [
                makeSettingsDetailBlock([
                    makeMetricsNumberSetting(
                        label: L10n.Settings.deviceMetricsRefreshIntervalSeconds,
                        field: deviceMetricsRefreshIntervalSecondsField,
                        rowIdentifier: "Stacio.Settings.deviceMetricsRefreshIntervalSecondsRow"
                    ),
                    makeControlColumnHelpLabel(
                        L10n.Settings.metricsRefreshHelp,
                        identifier: "Stacio.Settings.metricsRefreshHelp"
                    )
                ]),
                makeMetricsToggleSetting(button: deviceMetricsKeepLastSnapshotOnFailureButton)
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.metricsDisplayGroupTitle,
            detail: L10n.Settings.metricsDisplayGroupDescription,
            identifier: "Stacio.Settings.group.metricsDisplay",
            content: [
                makeForm(rows: [(L10n.Settings.deviceMetricsDisplayLocation, deviceMetricsDisplayLocationControl)]),
                makeControlColumnHelpLabel(
                    L10n.Settings.deviceMetricsDisplayLocationHelp,
                    identifier: "Stacio.Settings.deviceMetricsDisplayLocationHelp"
                ),
                makeMetricsToggleSetting(button: deviceMetricsShowNetworkSectionButton),
                makeSettingsDetailBlock([
                    makeMetricsToggleSetting(button: deviceMetricsShowDiskSectionButton),
                    makeControlColumnHelpLabel(
                        L10n.Settings.metricsModuleVisibilityHelp,
                        identifier: "Stacio.Settings.metricsModuleVisibilityHelp"
                    )
                ]),
                makeMetricsNumberSetting(
                    label: L10n.Settings.deviceMetricsDiskMountLimit,
                    field: deviceMetricsDiskMountLimitField,
                    rowIdentifier: "Stacio.Settings.deviceMetricsDiskMountLimitRow"
                ),
                makeSettingsDetailBlock([
                    makeMetricsNumberSetting(
                        label: L10n.Settings.deviceMetricsHistorySampleCount,
                        field: deviceMetricsHistorySampleCountField,
                        rowIdentifier: "Stacio.Settings.deviceMetricsHistorySampleCountRow"
                    ),
                    makeControlColumnHelpLabel(
                        L10n.Settings.metricsDisplayLimitsHelp,
                        identifier: "Stacio.Settings.metricsDisplayLimitsHelp"
                    )
                ])
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.metricsCompatibilityGroupTitle,
            detail: L10n.Settings.metricsCompatibilityGroupDescription,
            identifier: "Stacio.Settings.group.metricsCompatibility",
            content: [
                makeControlColumnHelpLabel(
                    L10n.Settings.metricsCompatibilityHelp,
                    identifier: "Stacio.Settings.metricsCompatibilityHelp"
                ),
                makeMetricsToggleSetting(button: deviceMetricsHideVirtualNetworkInterfacesButton)
            ]
        ))
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.metricsAlertsGroupTitle,
            detail: L10n.Settings.metricsAlertsGroupDescription,
            identifier: "Stacio.Settings.group.metricsAlerts",
            content: [
                makeSettingsDetailBlock([
                    makeMetricsToggleSetting(button: deviceMetricsAlertEnabledButton),
                    makeControlColumnHelpLabel(
                        L10n.Settings.metricsAlertNotificationHelp,
                        identifier: "Stacio.Settings.metricsAlertNotificationHelp"
                    )
                ]),
                makeMetricsNumberSetting(
                    label: L10n.Settings.deviceMetricsCPUAlertThresholdPercent,
                    field: deviceMetricsCPUAlertThresholdPercentField,
                    rowIdentifier: "Stacio.Settings.deviceMetricsCPUAlertThresholdPercentRow"
                ),
                makeMetricsNumberSetting(
                    label: L10n.Settings.deviceMetricsMemoryAlertThresholdPercent,
                    field: deviceMetricsMemoryAlertThresholdPercentField,
                    rowIdentifier: "Stacio.Settings.deviceMetricsMemoryAlertThresholdPercentRow"
                ),
                makeMetricsNumberSetting(
                    label: L10n.Settings.deviceMetricsDiskAlertThresholdPercent,
                    field: deviceMetricsDiskAlertThresholdPercentField,
                    rowIdentifier: "Stacio.Settings.deviceMetricsDiskAlertThresholdPercentRow"
                ),
                makeSettingsDetailBlock([
                    makeMetricsNumberSetting(
                        label: L10n.Settings.deviceMetricsAlertConsecutiveRefreshCount,
                        field: deviceMetricsAlertConsecutiveRefreshCountField,
                        rowIdentifier: "Stacio.Settings.deviceMetricsAlertConsecutiveRefreshCountRow"
                    ),
                    makeControlColumnHelpLabel(
                        L10n.Settings.metricsAlertThresholdHelp,
                        identifier: "Stacio.Settings.metricsAlertThresholdHelp"
                    )
                ])
            ]
        ))
        return stack
    }

    private func makeUpdatesPane() -> NSView {
        configureUpdateControls()
        refreshUpdateChannelPresentation()
        let stack = makePaneStack(section: .updates)
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.updateChannelGroupTitle,
            detail: L10n.Settings.updateChannelGroupDescription,
            identifier: "Stacio.Settings.group.updates",
            content: [
                makeSettingsPreferenceRow(
                    title: L10n.Settings.updateChannel,
                    detail: L10n.Settings.updateChannelHelp,
                    control: updateChannelControl,
                    identifier: "updateChannel"
                ),
                makeControlColumnRow(updateChannelStatusLabel)
            ]
        ))
        return stack
    }

    private func configureUpdateControls() {
        guard updateControlsConfigured == false else {
            return
        }
        updateControlsConfigured = true
        updateChannelControl.target = self
        updateChannelControl.action = #selector(updateChannelChanged(_:))
        updateChannelControl.setAccessibilityIdentifier("Stacio.Settings.updateChannel")
        updateChannelControl.segmentStyle = .automatic
        updateChannelControl.selectedSegment = 0
        updateChannelStatusLabel.setAccessibilityIdentifier("Stacio.Settings.updateChannelStatus")
        updateChannelStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        updateChannelStatusLabel.maximumNumberOfLines = 0
    }

    private func refreshUpdateChannelPresentation() {
        let channel = productOpsConfigurationStore.load().effectiveUpdateChannel
        updateChannelControl.selectedSegment = ProductOpsReleaseChannel.allCases.firstIndex(of: channel) ?? 0
        updateChannelStatusLabel.stringValue = L10n.Settings.updateChannelCurrent(channel.displayName)
    }

    @objc private func updateChannelChanged(_ sender: NSSegmentedControl) {
        let existing = productOpsConfigurationStore.load()
        let current = existing.effectiveUpdateChannel
        let channels = ProductOpsReleaseChannel.allCases
        let proposed = channels.indices.contains(sender.selectedSegment)
            ? channels[sender.selectedSegment]
            : current
        guard proposed != current else {
            refreshUpdateChannelPresentation()
            return
        }
        guard updateChannelConfirmation.confirmUpdateChannelChange(
            from: current,
            to: proposed,
            parentWindow: view.window
        ) else {
            refreshUpdateChannelPresentation()
            return
        }
        var updated = existing
        updated.updateChannel = proposed
        updated.betaUpdatesEnabled = proposed == .beta
        productOpsConfigurationStore.save(updated)
        refreshUpdateChannelPresentation()
    }

    private func makeSecurityPane() -> NSView {
        configureSecurityControls()
        let stack = makePaneStack(section: .security)
        let form = makeForm(rows: [
            (L10n.Settings.confirmationPolicy, securityConfirmationControl),
            (L10n.Settings.agentCommandAllowPatterns, securityAgentCommandAllowPatternsField),
            (L10n.Settings.agentCommandDenyPatterns, securityAgentCommandDenyPatternsField)
        ])
        stack.addArrangedSubview(makeSecurityStatusOverview())
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.securityApprovalGroupTitle,
            detail: L10n.Settings.securityApprovalGroupDescription,
            identifier: "Stacio.Settings.group.securityApproval",
            content: [
                makeSettingsDetailBlock([
                    form,
                    makeControlColumnHelpLabel(
                        L10n.Settings.securityCommandPolicyHelp,
                        identifier: "Stacio.Settings.securityCommandPolicyHelp"
                    )
                ]),
                makeApprovalRiskMatrixLabel(
                    securityApprovalRiskMatrixLabel,
                    identifier: "Stacio.Settings.securityApprovalRiskMatrix"
                )
            ]
        ))
        stack.addArrangedSubview(makeSessionPolicyGroup())
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.securityAuditGroupTitle,
            detail: L10n.Settings.securityAuditGroupDescription,
            identifier: "Stacio.Settings.group.securityAudit",
            content: [
                makeSettingsDetailBlock([
                    makeForm(rows: [
                        (L10n.Settings.diagnosticsAuditExportLimit, diagnosticsAuditExportLimitField),
                        (L10n.Settings.diagnosticsAppLogLineLimit, diagnosticsAppLogLineLimitField)
                    ]),
                    makeControlColumnHelpLabel(
                        L10n.Settings.diagnosticsExportLimitHelp,
                        identifier: "Stacio.Settings.diagnosticsExportLimitHelp"
                    )
                ]),
                makeSettingsDetailBlock([
                    makeControlColumnRow(diagnosticsIncludeAppLogsButton),
                    makeControlColumnHelpLabel(
                        L10n.Settings.securityAuditHelp,
                        identifier: "Stacio.Settings.securityAuditHelp"
                    )
                ])
            ]
        ))
        stack.addArrangedSubview(makeCredentialCenterGroup())
        stack.addArrangedSubview(makeSecurityStorageGroup())
        return stack
    }

    // MARK: - Oh My Zsh

    private func makeOhMyZshPane() -> NSView {
        configureOhMyZshControls()
        let stack = makePaneStack(section: .ohMyZsh)

        // 资源组：下载/卸载 + 状态
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.ohMyZshResourcesGroupTitle,
            detail: L10n.Settings.ohMyZshResourcesGroupDescription,
            identifier: "Stacio.Settings.group.ohMyZshResources",
            content: [
                makeSettingsStatusActionRow(
                    label: ohMyZshResourceStatusLabel,
                    action: ohMyZshDownloadButton
                ),
                makeSettingsStatusActionRow(
                    label: makeHelpLabel(
                        L10n.Settings.ohMyZshResourcesGroupDescription,
                        identifier: "Stacio.Settings.ohMyZshResourceHelp",
                        maximumWidth: AppSettingsLayout.settingsListContentWidth
                    ),
                    action: ohMyZshUninstallResourceButton
                )
            ]
        ))

        // 配置组：启用开关 + 主题 + 预览 + 插件 + 附加 zshrc
        let themeRow = makeFormRow(label: L10n.Settings.ohMyZshTheme, control: ohMyZshThemePopup)
        let extraRow = makeFormRow(label: L10n.Settings.ohMyZshExtraZshrc, control: ohMyZshExtraZshrcField)
        ohMyZshExtraZshrcField.placeholderString = L10n.Settings.ohMyZshExtraZshrcHelp
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.ohMyZshConfigurationGroupTitle,
            detail: L10n.Settings.ohMyZshConfigurationGroupDescription,
            identifier: "Stacio.Settings.group.ohMyZshConfiguration",
            content: [
                makeSettingsPreferenceToggleRow(
                    title: L10n.Settings.ohMyZshEnable,
                    detail: L10n.Settings.ohMyZshEnableHelp,
                    button: ohMyZshEnableButton,
                    identifier: "ohMyZshEnable"
                ),
                makeSettingsDetailBlock([
                    themeRow,
                    ohMyZshThemePreviewView,
                    makeControlColumnHelpLabel(
                        L10n.Settings.ohMyZshPluginsHelp,
                        identifier: "Stacio.Settings.ohMyZshPluginsHelp"
                    ),
                    ohMyZshPluginsScrollView,
                    extraRow,
                    makeControlColumnHelpLabel(
                        L10n.Settings.ohMyZshExtraZshrcHelp,
                        identifier: "Stacio.Settings.ohMyZshExtraZshrcHelp"
                    )
                ])
            ]
        ))

        // 生效范围组
        stack.addArrangedSubview(makeSettingsGroup(
            title: L10n.Settings.ohMyZshScopeGroupTitle,
            detail: L10n.Settings.ohMyZshScopeGroupDescription,
            identifier: "Stacio.Settings.group.ohMyZshScope",
            content: [
                makeSettingsNoteRow(makeHelpLabel(
                    L10n.Settings.ohMyZshScopeLocal,
                    identifier: "Stacio.Settings.ohMyZshScopeLocal",
                    maximumWidth: AppSettingsLayout.settingsListContentWidth
                )),
                makeSettingsNoteRow(makeHelpLabel(
                    L10n.Settings.ohMyZshScopeRemote,
                    identifier: "Stacio.Settings.ohMyZshScopeRemote",
                    maximumWidth: AppSettingsLayout.settingsListContentWidth
                )),
                makeSettingsNoteRow(makeHelpLabel(
                    L10n.Settings.ohMyZshScopeSession,
                    identifier: "Stacio.Settings.ohMyZshScopeSession",
                    maximumWidth: AppSettingsLayout.settingsListContentWidth
                ))
            ]
        ))

        refreshOhMyZshPresentation()
        return stack
    }

    private func configureOhMyZshControls() {
        guard ohMyZshControlsConfigured == false else { return }
        ohMyZshControlsConfigured = true

        let snapshot = settingsStore.snapshot()

        ohMyZshDownloadButton.target = self
        ohMyZshDownloadButton.action = #selector(ohMyZshDownloadPressed(_:))
        ohMyZshDownloadButton.bezelStyle = .rounded
        ohMyZshDownloadButton.setAccessibilityIdentifier("Stacio.Settings.ohMyZshDownload")

        ohMyZshUninstallResourceButton.target = self
        ohMyZshUninstallResourceButton.action = #selector(ohMyZshUninstallResourcePressed(_:))
        ohMyZshUninstallResourceButton.bezelStyle = .rounded
        ohMyZshUninstallResourceButton.setAccessibilityIdentifier("Stacio.Settings.ohMyZshUninstallResource")

        ohMyZshResourceSpinner.style = .spinning
        ohMyZshResourceSpinner.isIndeterminate = true
        ohMyZshResourceSpinner.controlSize = .small
        ohMyZshResourceSpinner.isHidden = true

        configurePreferenceToggleButton(ohMyZshEnableButton)
        ohMyZshEnableButton.state = snapshot.ohmyzshEnabled ? .on : .off
        ohMyZshEnableButton.target = self
        ohMyZshEnableButton.action = #selector(ohMyZshEnableChanged(_:))
        ohMyZshEnableButton.setAccessibilityIdentifier("Stacio.Settings.ohMyZshEnable")

        ohMyZshThemePopup.target = self
        ohMyZshThemePopup.action = #selector(ohMyZshThemeChanged(_:))
        ohMyZshThemePopup.setAccessibilityIdentifier("Stacio.Settings.ohMyZshTheme")
        StacioDesignSystem.stylePopupButton(ohMyZshThemePopup)
        ohMyZshThemePopup.widthAnchor.constraint(equalToConstant: AppSettingsLayout.popupWidth).isActive = true

        ohMyZshExtraZshrcField.target = self
        ohMyZshExtraZshrcField.action = #selector(ohMyZshExtraZshrcChanged(_:))
        ohMyZshExtraZshrcField.setAccessibilityIdentifier("Stacio.Settings.ohMyZshExtraZshrc")

        ohMyZshPluginsStack.orientation = .vertical
        ohMyZshPluginsStack.alignment = .width
        ohMyZshPluginsStack.spacing = 6
        ohMyZshPluginsStack.translatesAutoresizingMaskIntoConstraints = false
        ohMyZshPluginsScrollView.translatesAutoresizingMaskIntoConstraints = false
        ohMyZshPluginsScrollView.hasVerticalScroller = true
        ohMyZshPluginsScrollView.autohidesScrollers = true
        ohMyZshPluginsScrollView.borderType = .noBorder
        ohMyZshPluginsScrollView.drawsBackground = true
        ohMyZshPluginsScrollView.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.42)
        ohMyZshPluginsScrollView.setAccessibilityIdentifier("Stacio.Settings.ohMyZshPlugins")
        ohMyZshPluginsScrollView.wantsLayer = true
        ohMyZshPluginsScrollView.layer?.cornerRadius = 8
        ohMyZshPluginsScrollView.layer?.masksToBounds = true
        let pluginsDocumentView = AppSettingsFlippedDocumentView()
        pluginsDocumentView.translatesAutoresizingMaskIntoConstraints = false
        pluginsDocumentView.addSubview(ohMyZshPluginsStack)
        // 先赋 documentView 再激活跨视图约束（documentView 需为共同祖先；
        // 顺序颠倒会抛 NSGenericException "no common ancestor" 导致 pane 构造中断、
        // 设置窗口空白且无法切换其他分区）
        ohMyZshPluginsScrollView.documentView = pluginsDocumentView
        NSLayoutConstraint.activate([
            ohMyZshPluginsScrollView.widthAnchor.constraint(
                equalToConstant: AppSettingsLayout.settingsListContentWidth
            ),
            pluginsDocumentView.widthAnchor.constraint(equalTo: ohMyZshPluginsScrollView.contentView.widthAnchor),
            ohMyZshPluginsStack.topAnchor.constraint(equalTo: pluginsDocumentView.topAnchor, constant: 8),
            ohMyZshPluginsStack.leadingAnchor.constraint(equalTo: pluginsDocumentView.leadingAnchor, constant: 10),
            ohMyZshPluginsStack.trailingAnchor.constraint(equalTo: pluginsDocumentView.trailingAnchor, constant: -10),
            ohMyZshPluginsStack.bottomAnchor.constraint(equalTo: pluginsDocumentView.bottomAnchor, constant: -8),
            ohMyZshPluginsScrollView.heightAnchor.constraint(
                equalToConstant: AppSettingsLayout.ohMyZshPluginListHeight
            )
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ohMyZshSettingsStoreDidChange(_:)),
            name: AppSettingsStore.didChangeNotification,
            object: settingsStore
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ohMyZshResourceStatusDidChange(_:)),
            name: OhMyZshResourceManager.statusDidChangeNotification,
            object: OhMyZshResourceManager.shared
        )
    }

    private func refreshOhMyZshPresentation() {
        let snapshot = settingsStore.snapshot()
        let manager = OhMyZshResourceManager.shared
        let status = manager.status()
        let installedDirectoryURL = manager.installedDirectoryURL
        let catalog = OhMyZshCatalog(directoryURL: installedDirectoryURL)

        // 资源状态
        let statusText: String
        if status.isValidating {
            statusText = L10n.Settings.ohMyZshValidating
        } else if status.isBusy {
            statusText = L10n.Settings.ohMyZshDownloading
        } else if let version = status.installedVersion {
            statusText = "\(L10n.Settings.ohMyZshStatusInstalled) v\(version)"
        } else if status.requiresRedownload {
            statusText = L10n.Settings.ohMyZshStatusRequiresRedownload
        } else {
            statusText = L10n.Settings.ohMyZshStatusNotInstalled
        }
        ohMyZshResourceStatusLabel.stringValue = statusText
        ohMyZshResourceStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        ohMyZshDownloadButton.title = (status.isInstalled || status.requiresRedownload)
            ? L10n.Settings.ohMyZshReDownload
            : L10n.Settings.ohMyZshDownload
        ohMyZshDownloadButton.isEnabled = status.isBusy == false && ohMyZshDownloadRequestInFlight == false
        ohMyZshUninstallResourceButton.isEnabled = status.isInstalled && status.isBusy == false

        // 启用开关：未下载资源时禁用（防止启用却无资源）
        ohMyZshEnableButton.state = snapshot.ohmyzshEnabled ? .on : .off
        if status.isInstalled == false {
            ohMyZshEnableButton.isEnabled = false
        } else {
            ohMyZshEnableButton.isEnabled = true
        }

        // 主题下拉：从 catalog 填充
        let themes = catalog.themes().map(\.name)
        let currentTheme = snapshot.ohmyzshTheme ?? OhMyZshConfigResolver.defaultThemeName
        ohMyZshThemePopup.removeAllItems()
        if themes.isEmpty {
            ohMyZshThemePopup.addItem(withTitle: currentTheme)
        } else {
            ohMyZshThemePopup.addItems(withTitles: themes)
        }
        if let item = ohMyZshThemePopup.item(withTitle: currentTheme) {
            ohMyZshThemePopup.select(item)
        } else if ohMyZshThemePopup.numberOfItems > 0 {
            ohMyZshThemePopup.selectItem(at: 0)
        }
        ohMyZshThemePopup.isEnabled = status.isInstalled

        // 主题预览
        if status.isInstalled {
            ohMyZshThemePreviewView.render(
                theme: currentTheme,
                resourceDirectoryURL: installedDirectoryURL
            )
        } else {
            ohMyZshThemePreviewView.render(theme: currentTheme, resourceDirectoryURL: nil)
        }

        // 插件列表
        refreshOhMyZshPluginsList(catalog: catalog, enabledPlugins: snapshot.ohmyzshPlugins)

        // 附加 zshrc
        ohMyZshExtraZshrcField.stringValue = snapshot.ohmyzshExtraZshrcLines ?? ""
        ohMyZshExtraZshrcField.isEnabled = status.isInstalled
    }

    private func refreshOhMyZshPluginsList(catalog: OhMyZshCatalog, enabledPlugins: [String]) {
        ohMyZshPluginsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let enabled = Set(enabledPlugins)
        if catalog.isAvailable == false || catalog.plugins().isEmpty {
            let label = NSTextField(labelWithString: L10n.Settings.ohMyZshResourceRequired)
            label.font = .systemFont(ofSize: 12)
            label.textColor = StacioDesignSystem.theme.secondaryTextColor
            label.translatesAutoresizingMaskIntoConstraints = false
            ohMyZshPluginsStack.addArrangedSubview(label)
            return
        }
        let entries = catalog.plugins()
        let columnCount = 3
        for rowStart in stride(from: 0, to: entries.count, by: columnCount) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false
            row.setAccessibilityIdentifier("Stacio.Settings.ohMyZshPluginRow.\(rowStart / columnCount)")

            for column in 0..<columnCount {
                let entryIndex = rowStart + column
                guard entryIndex < entries.count else {
                    let spacer = NSView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    row.addArrangedSubview(spacer)
                    continue
                }

                let entry = entries[entryIndex]
                let toggle = NSButton(checkboxWithTitle: entry.name, target: nil, action: nil)
                toggle.state = enabled.contains(entry.name) ? .on : .off
                toggle.target = self
                toggle.action = #selector(ohMyZshPluginToggled(_:))
                toggle.lineBreakMode = .byTruncatingTail
                toggle.setAccessibilityIdentifier("Stacio.Settings.ohMyZshPlugin.\(entry.name)")
                toggle.toolTip = entry.summary.isEmpty ? entry.name : entry.summary
                toggle.translatesAutoresizingMaskIntoConstraints = false
                toggle.setContentHuggingPriority(.defaultLow, for: .horizontal)
                toggle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(toggle)
            }

            ohMyZshPluginsStack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: ohMyZshPluginsStack.widthAnchor),
                row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
            ])
        }
    }

    @objc private func ohMyZshSettingsStoreDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshOhMyZshPresentation()
        }
    }

    @objc private func ohMyZshResourceStatusDidChange(_ notification: Notification) {
        refreshOhMyZshPresentation()
    }

    @objc private func ohMyZshDownloadPressed(_ sender: NSButton) {
        guard ohMyZshDownloadRequestInFlight == false else { return }
        ohMyZshDownloadRequestInFlight = true
        sender.isEnabled = false
        ohMyZshResourceSpinner.isHidden = false
        ohMyZshResourceSpinner.startAnimation(nil)
        ohMyZshResourceStatusLabel.stringValue = L10n.Settings.ohMyZshDownloading
        let manager = OhMyZshResourceManager.shared
        manager.download { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ohMyZshResourceSpinner.stopAnimation(nil)
                self.ohMyZshResourceSpinner.isHidden = true
                self.ohMyZshDownloadRequestInFlight = false
                switch result {
                case .success:
                    self.refreshOhMyZshPresentation()
                case let .failure(error):
                    self.ohMyZshResourceStatusLabel.stringValue = L10n.Settings.ohMyZshInstallFailed
                    self.ohMyZshResourceStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                    self.ohMyZshResourceStatusLabel.toolTip = error.localizedDescription
                }
            }
        }
        // 后台下载完成时（即使本窗口已关闭）由系统通知提示；这里轮询以刷新状态
        ohMyZshResourcePollingTimer?.invalidate()
        ohMyZshResourcePollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let status = OhMyZshResourceManager.shared.status()
            if status.isBusy == false && self.ohMyZshDownloadRequestInFlight == false {
                timer.invalidate()
                self.ohMyZshResourcePollingTimer = nil
                self.refreshOhMyZshPresentation()
            }
        }
    }

    @objc private func ohMyZshUninstallResourcePressed(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = L10n.Settings.ohMyZshUninstallResource
        alert.informativeText = L10n.Settings.ohMyZshUninstallResourceConfirm
        alert.addButton(withTitle: L10n.Common.ok)
        alert.addButton(withTitle: L10n.Common.cancel)
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try OhMyZshResourceManager.shared.uninstall(settingsStore: settingsStore)
            refreshOhMyZshPresentation()
        } catch {
            ohMyZshResourceStatusLabel.stringValue = L10n.Settings.ohMyZshInstallFailed
            ohMyZshResourceStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
            ohMyZshResourceStatusLabel.toolTip = error.localizedDescription
        }
    }

    @objc private func ohMyZshEnableChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        if enabled && OhMyZshResourceManager.shared.status().isInstalled == false {
            sender.state = .off
            return
        }
        settingsStore.update { $0.ohmyzshEnabled = enabled }
    }

    @objc private func ohMyZshThemeChanged(_ sender: NSPopUpButton) {
        let theme = sender.titleOfSelectedItem ?? OhMyZshConfigResolver.defaultThemeName
        settingsStore.update { $0.ohmyzshTheme = theme }
        ohMyZshThemePreviewView.render(
            theme: theme,
            resourceDirectoryURL: OhMyZshResourceManager.shared.installedDirectoryURL
        )
    }

    @objc private func ohMyZshPluginToggled(_ sender: NSButton) {
        let pluginName = sender.title
        settingsStore.update { settings in
            var plugins = settings.ohmyzshPlugins
            if sender.state == .on {
                if plugins.contains(pluginName) == false {
                    plugins.append(pluginName)
                }
            } else {
                plugins.removeAll { $0 == pluginName }
                if plugins.isEmpty { plugins = ["git"] }
            }
            settings.ohmyzshPlugins = plugins
        }
    }

    @objc private func ohMyZshExtraZshrcChanged(_ sender: NSTextField) {
        settingsStore.update { $0.ohmyzshExtraZshrcLines = sender.stringValue }
    }

    private func makePlaceholderPane(section: AppSettingsSection, message: String) -> NSView {
        let stack = makePaneStack(section: section)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 470)
        ])
        return stack
    }

    private func makePaneStack(section: AppSettingsSection) -> NSStackView {
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        switch section {
        case .terminal:
            title.setAccessibilityIdentifier("Stacio.Settings.terminalTitle")
        case .terminalTheme:
            title.setAccessibilityIdentifier("Stacio.Settings.terminalThemeTitle")
        default:
            title.setAccessibilityIdentifier(nil)
        }

        let detail = NSTextField(labelWithString: section.detail)
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = StacioDesignSystem.theme.secondaryTextColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        detail.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(24, after: detail)
        NSLayoutConstraint.activate([
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.readableTextWidth),
            stack.widthAnchor.constraint(equalToConstant: AppSettingsLayout.paneWidth)
        ])
        return stack
    }

    private func makeHelpLabel(
        _ text: String,
        identifier: String? = nil,
        maximumWidth: CGFloat = AppSettingsLayout.readableTextWidth
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier(identifier)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(lessThanOrEqualToConstant: maximumWidth)
        ])
        return label
    }

    private func makeControlColumnHelpLabel(_ text: String, identifier: String? = nil) -> NSView {
        let label = makeHelpLabel(
            text,
            identifier: identifier,
            maximumWidth: AppSettingsLayout.settingsListContentWidth
        )
        return makeSettingsNoteRow(label)
    }

    private func makeSettingsDetailBlock(_ rows: [NSView]) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth)
        ])
        return stack
    }

    private func makeControlColumnRow(_ content: NSView) -> NSView {
        if let button = content as? NSButton, isSettingsToggleButton(button) {
            return makeSettingsInlineToggleRow(button)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [spacer, content])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = AppSettingsLayout.formColumnSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spacer.widthAnchor.constraint(equalToConstant: AppSettingsLayout.labelColumnWidth),
            row.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.settingsControlRowMinHeight)
        ])
        return row
    }

    private func makeSettingsInlineToggleRow(_ button: NSButton) -> NSView {
        configurePreferenceToggleButton(button)
        let switchProxy = AppSettingsSwitchProxy(backingButton: button)

        let titleLabel = NSTextField(labelWithString: button.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("\(button.accessibilityIdentifier()).label")

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [titleLabel, spacer, switchProxy])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("\(button.accessibilityIdentifier()).row")

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.settingsControlRowMinHeight),
            titleLabel.widthAnchor.constraint(
                lessThanOrEqualToConstant: AppSettingsLayout.settingsListContentWidth
                    - AppSettingsLayout.settingsSwitchSize.width
                    - 12
            ),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        return row
    }

    private func makeSettingsNoteRow(_ label: NSTextField) -> NSView {
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let identifier = label.accessibilityIdentifier()
        if identifier.isEmpty == false {
            row.setAccessibilityIdentifier("\(identifier).row")
        }
        row.addSubview(label)

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.settingsNoteRowMinHeight),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7)
        ])
        return row
    }

    private func makeSettingsStatusActionRow(label: NSTextField, action: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label, spacer, action])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.settingsControlRowMinHeight),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.settingsListContentWidth - 148),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        return row
    }

    private func makeSettingsPreferenceToggleRow(
        title: String,
        detail: String,
        button: NSButton,
        identifier: String
    ) -> NSView {
        configurePreferenceToggleButton(button)
        return makeSettingsPreferenceRow(
            title: title,
            detail: detail,
            control: AppSettingsSwitchProxy(backingButton: button),
            identifier: identifier
        )
    }

    private func makeSettingsPreferenceRow(
        title: String,
        detail: String,
        control: NSView,
        identifier: String
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("Stacio.Settings.preferenceTitle.\(identifier)")

        let detailLabel = makeHelpLabel(
            detail,
            identifier: "Stacio.Settings.preferenceHelp.\(identifier)",
            maximumWidth: AppSettingsLayout.settingsListContentWidth
        )
        detailLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let topRow = NSStackView(views: [titleLabel, spacer, control])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = AppSettingsLayout.preferenceRowControlSpacing
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.setAccessibilityIdentifier("Stacio.Settings.preferenceTopRow.\(identifier)")

        let row = NSStackView(views: [topRow, detailLabel])
        row.orientation = .vertical
        row.alignment = .width
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("Stacio.Settings.preferenceRow.\(identifier)")

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.preferenceRowMinHeight),
            topRow.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            topRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            detailLabel.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        return row
    }

    private func configurePreferenceToggleButton(_ button: NSButton) {
        let currentState = button.state
        button.setButtonType(.toggle)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = nil
        button.alternateImage = nil
        button.imagePosition = .noImage
        button.contentTintColor = nil
        button.translatesAutoresizingMaskIntoConstraints = false
        button.state = currentState
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.toolTip = button.title
    }

    private func isSettingsToggleButton(_ button: NSButton) -> Bool {
        button.isBordered == false
            && button.bezelStyle == .regularSquare
            && button.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func makeFilesToggleSetting(button: NSButton, help: String, helpIdentifier: String? = nil) -> NSView {
        let identifier = button.accessibilityIdentifier()
            .replacingOccurrences(of: "Stacio.Settings.", with: "")
        return makeSettingsPreferenceToggleRow(
            title: button.title,
            detail: help,
            button: button,
            identifier: identifier
        )
    }

    private func makeFilesConflictPolicyRow() -> NSView {
        makeSettingsControlRow(
            label: L10n.Settings.filesTransferConflictPolicy,
            control: filesTransferConflictPolicyPopup,
            rowIdentifier: "Stacio.Settings.filesTransferConflictPolicyRow",
            labelIdentifier: "Stacio.Settings.filesTransferConflictPolicy.label"
        )
    }

    private func makeMetricsNumberSetting(label text: String, field: NSTextField, rowIdentifier: String) -> NSView {
        makeSettingsControlRow(
            label: text,
            control: field,
            rowIdentifier: rowIdentifier,
            labelIdentifier: "\(field.accessibilityIdentifier()).label"
        )
    }

    private func makeMetricsToggleSetting(button: NSButton) -> NSView {
        let row = makeControlColumnRow(button)
        row.setAccessibilityIdentifier("\(button.accessibilityIdentifier()).row")
        return row
    }

    private func makeApprovalRiskMatrixLabel(_ label: NSTextField, identifier: String) -> NSTextField {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier(identifier)
        label.stringValue = approvalRiskMatrixText(for: settingsStore.snapshot().agentConfirmationPolicy)
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.readableTextWidth)
        ])
        return label
    }

    private func makeAIStatusOverview() -> NSView {
        refreshAISummary()

        configureSummaryLabel(
            aiSummaryProviderLabel,
            identifier: "Stacio.Settings.aiSummary.provider"
        )
        configureSummaryLabel(
            aiSummaryApprovalLabel,
            identifier: "Stacio.Settings.aiSummary.approval"
        )
        configureSummaryLabel(
            aiSummaryExecutionLabel,
            identifier: "Stacio.Settings.aiSummary.execution"
        )

        return makeStatusOverview(
            identifier: "Stacio.Settings.aiSummary",
            title: L10n.Settings.aiStatusGroupTitle,
            detail: L10n.Settings.aiStatusGroupDescription,
            rows: [
                makeSummaryRow(symbolName: "sparkles", label: aiSummaryProviderLabel),
                makeSummaryRow(symbolName: "checkmark.shield", label: aiSummaryApprovalLabel),
                makeSummaryRow(symbolName: "terminal", label: aiSummaryExecutionLabel)
            ]
        )
    }

    private func makeFilesStatusOverview() -> NSView {
        refreshFilesSummary()

        configureSummaryLabel(
            filesSummaryDirectoryFollowLabel,
            identifier: "Stacio.Settings.filesSummary.directoryFollow"
        )
        configureSummaryLabel(
            filesSummaryRemoteEditAutoDetectLabel,
            identifier: "Stacio.Settings.filesSummary.remoteEditAutoDetect"
        )
        return makeStatusOverview(
            identifier: "Stacio.Settings.filesSummary",
            title: L10n.Settings.filesStatusGroupTitle,
            detail: L10n.Settings.filesStatusGroupDescription,
            rows: [
                makeSummaryRow(symbolName: "folder.badge.gearshape", label: filesSummaryDirectoryFollowLabel),
                makeSummaryRow(symbolName: "square.and.arrow.up.on.square", label: filesSummaryRemoteEditAutoDetectLabel)
            ]
        )
    }

    private func makeMetricsStatusOverview() -> NSView {
        refreshMetricsSummary()

        configureSummaryLabel(
            metricsSummaryCollectionLabel,
            identifier: "Stacio.Settings.metricsSummary.collection"
        )
        configureSummaryLabel(
            metricsSummaryDisplayLabel,
            identifier: "Stacio.Settings.metricsSummary.display"
        )
        return makeStatusOverview(
            identifier: "Stacio.Settings.metricsSummary",
            title: L10n.Settings.metricsStatusGroupTitle,
            detail: L10n.Settings.metricsStatusGroupDescription,
            rows: [
                makeSummaryRow(symbolName: "gauge.with.dots.needle.67percent", label: metricsSummaryCollectionLabel),
                makeSummaryRow(symbolName: "chart.line.uptrend.xyaxis", label: metricsSummaryDisplayLabel)
            ]
        )
    }

    private func makeSecurityStatusOverview() -> NSView {
        refreshSecuritySummary()

        configureSummaryLabel(
            securitySummaryApprovalLabel,
            identifier: "Stacio.Settings.securitySummary.approval"
        )
        configureSummaryLabel(
            securitySummaryCredentialLabel,
            identifier: "Stacio.Settings.securitySummary.credentials"
        )
        configureSummaryLabel(
            securitySummaryAuditLabel,
            identifier: "Stacio.Settings.securitySummary.audit"
        )
        return makeStatusOverview(
            identifier: "Stacio.Settings.securitySummary",
            title: L10n.Settings.securityStatusGroupTitle,
            detail: L10n.Settings.securityStatusGroupDescription,
            rows: [
                makeSummaryRow(symbolName: "checkmark.shield", label: securitySummaryApprovalLabel),
                makeSummaryRow(symbolName: "key", label: securitySummaryCredentialLabel),
                makeSummaryRow(symbolName: "list.clipboard", label: securitySummaryAuditLabel)
            ]
        )
    }

    private func makeStatusOverview(
        identifier: String,
        title: String,
        detail: String,
        rows: [NSView]
    ) -> NSView {
        let container = makeGroupedSurface(identifier: identifier)
        let titleLabel = makeGroupTitleLabel(title)
        let detailLabel = makeGroupDetailLabel(detail)
        let summaryStack = NSStackView(views: rows)
        summaryStack.orientation = .horizontal
        summaryStack.alignment = .top
        summaryStack.spacing = 10
        summaryStack.distribution = .fillEqually
        summaryStack.translatesAutoresizingMaskIntoConstraints = false

        let list = makeSettingsListSurface(identifier: "\(identifier).rows", rows: [summaryStack])

        let stack = NSStackView(views: [titleLabel, detailLabel, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: detailLabel)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: AppSettingsLayout.groupWidth),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeSettingsGroup(
        title: String,
        detail: String,
        identifier: String,
        content: [NSView]
    ) -> NSView {
        let container = makeGroupedSurface(identifier: identifier)
        let titleLabel = makeGroupTitleLabel(title)
        let detailLabel = makeGroupDetailLabel(detail)
        let list = makeSettingsListSurface(identifier: "\(identifier).rows", rows: content)
        let stack = NSStackView(views: [titleLabel, detailLabel, list])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: detailLabel)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: AppSettingsLayout.groupWidth),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeAgentBridgeGroup() -> NSView {
        let socketPath = (try? StacioPaths.agentBridgeSocketPath().path)
            ?? "~/Library/Application Support/Stacio/agent-bridge.sock"
        agentBridgeSocketLabel.stringValue = socketPath
        agentBridgeSocketLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        agentBridgeSocketLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        agentBridgeSocketLabel.lineBreakMode = .byTruncatingMiddle
        agentBridgeSocketLabel.maximumNumberOfLines = 1
        agentBridgeSocketLabel.isSelectable = true
        agentBridgeSocketLabel.setAccessibilityIdentifier("Stacio.Settings.agentBridgeSocket")
        agentBridgeSocketLabel.translatesAutoresizingMaskIntoConstraints = false

        copyAgentBridgeSocketButton.target = self
        copyAgentBridgeSocketButton.action = #selector(copyAgentBridgeSocketPressed(_:))
        copyAgentBridgeSocketButton.bezelStyle = .rounded
        copyAgentBridgeSocketButton.setAccessibilityIdentifier("Stacio.Settings.copyAgentBridgeSocket")
        copyAgentBridgeSocketButton.translatesAutoresizingMaskIntoConstraints = false

        let socketRowContent = NSStackView(views: [agentBridgeSocketLabel, copyAgentBridgeSocketButton])
        socketRowContent.orientation = .horizontal
        socketRowContent.alignment = .centerY
        socketRowContent.spacing = 10
        socketRowContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            agentBridgeSocketLabel.widthAnchor.constraint(equalToConstant: AppSettingsLayout.pathLabelWidth),
            copyAgentBridgeSocketButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        let socketForm = makeForm(rows: [(L10n.Settings.agentBridgeSocket, socketRowContent)])
        let hint = makeHelpLabel(L10n.Settings.agentBridgeHint)
        hint.setAccessibilityIdentifier("Stacio.Settings.agentBridgeHint")
        return makeSettingsGroup(
            title: L10n.Settings.agentBridgeGroupTitle,
            detail: L10n.Settings.agentBridgeGroupDescription,
            identifier: "Stacio.Settings.group.agentBridge",
            content: [
                makeSettingsDetailBlock([
                    socketForm,
                    makeControlColumnRow(hint)
                ])
            ]
        )
    }

    private func makeAIModelCatalogGroup() -> NSView {
        refreshAIModelCatalogControls()
        let catalogButtons = NSStackView(views: [
            aiRefreshModelsButton,
            aiAddCustomModelButton
        ])
        catalogButtons.orientation = .horizontal
        catalogButtons.alignment = .centerY
        catalogButtons.spacing = 8
        catalogButtons.translatesAutoresizingMaskIntoConstraints = false

        let catalogActions = NSStackView(views: [
            aiModelCatalogPopup,
            catalogButtons
        ])
        catalogActions.orientation = .vertical
        catalogActions.alignment = .leading
        catalogActions.spacing = 7
        catalogActions.translatesAutoresizingMaskIntoConstraints = false
        catalogActions.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth).isActive = true

        let form = makeForm(rows: [
            (L10n.Settings.aiModelCatalog, catalogActions),
            (L10n.Settings.aiReasoningEffort, aiReasoningEffortControl),
            (L10n.Settings.aiCompatibilityProtocol, aiCompatibilityProtocolControl)
        ])
        return makeSettingsGroup(
            title: L10n.Settings.aiModelCatalogGroupTitle,
            detail: L10n.Settings.aiModelCatalogGroupDescription,
            identifier: "Stacio.Settings.group.aiModelCatalog",
            content: [
                form,
                makeSettingsDetailBlock([
                    makeControlColumnRow(aiCustomModelListScrollView),
                    makeSettingsNoteRow(aiModelCatalogStatusLabel),
                    makeControlColumnHelpLabel(L10n.Settings.aiModelCatalogHelp)
                ])
            ]
        )
    }

    private func makeSecurityStorageGroup() -> NSView {
        configureOperationalPathLabels()
        let form = makeForm(rows: [
            (
                L10n.Settings.applicationSupport,
                makeCopyablePathRow(
                    label: applicationSupportPathLabel,
                    button: copyApplicationSupportPathButton,
                    identifier: "Stacio.Settings.copy.applicationSupportPath",
                    action: #selector(copyApplicationSupportPathPressed(_:))
                )
            ),
            (
                L10n.Settings.database,
                makeCopyablePathRow(
                    label: databasePathLabel,
                    button: copyDatabasePathButton,
                    identifier: "Stacio.Settings.copy.databasePath",
                    action: #selector(copyDatabasePathPressed(_:))
                )
            ),
            (
                L10n.Settings.appLog,
                makeCopyablePathRow(
                    label: logPathLabel,
                    button: copyLogPathButton,
                    identifier: "Stacio.Settings.copy.logPath",
                    action: #selector(copyLogPathPressed(_:))
                )
            )
        ])
        return makeSettingsGroup(
            title: L10n.Settings.securityStorageGroupTitle,
            detail: L10n.Settings.securityStorageGroupDescription,
            identifier: "Stacio.Settings.group.securityStorage",
            content: [form]
        )
    }

    private func makeCredentialCenterGroup() -> NSView {
        refreshCredentialCenter()
        credentialCenterListPopup.target = self
        credentialCenterListPopup.action = #selector(credentialCenterSelectionChanged(_:))
        credentialCenterListPopup.setAccessibilityIdentifier("Stacio.Settings.credentialCenterList")
        StacioDesignSystem.stylePopupButton(credentialCenterListPopup)

        credentialCenterRefreshButton.target = self
        credentialCenterRefreshButton.action = #selector(refreshCredentialCenterPressed(_:))
        credentialCenterRefreshButton.title = ""
        credentialCenterRefreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: L10n.Settings.credentialCenterRefresh
        )
        credentialCenterRefreshButton.imagePosition = .imageOnly
        credentialCenterRefreshButton.toolTip = L10n.Settings.credentialCenterRefresh
        credentialCenterRefreshButton.setAccessibilityLabel(L10n.Settings.credentialCenterRefresh)
        credentialCenterRefreshButton.setAccessibilityIdentifier("Stacio.Settings.credentialCenterRefresh")
        credentialCenterRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSheetButton(credentialCenterRefreshButton)

        credentialCenterDeleteButton.target = self
        credentialCenterDeleteButton.action = #selector(deleteCredentialCenterSelectionPressed(_:))
        credentialCenterDeleteButton.title = ""
        credentialCenterDeleteButton.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: L10n.Settings.credentialCenterDelete
        )
        credentialCenterDeleteButton.imagePosition = .imageOnly
        credentialCenterDeleteButton.toolTip = L10n.Settings.credentialCenterDelete
        credentialCenterDeleteButton.setAccessibilityLabel(L10n.Settings.credentialCenterDelete)
        credentialCenterDeleteButton.setAccessibilityIdentifier("Stacio.Settings.credentialCenterDelete")
        credentialCenterDeleteButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSheetButton(credentialCenterDeleteButton)
        credentialCenterDeleteButton.contentTintColor = .systemRed

        configureCredentialCenterTextField(
            credentialCenterNewLabelField,
            identifier: "Stacio.Settings.credentialCenterNewLabel",
            placeholder: L10n.Settings.credentialCenterNewLabelPlaceholder,
            isSecure: false
        )
        configureCredentialCenterTextField(
            credentialCenterNewAccountField,
            identifier: "Stacio.Settings.credentialCenterNewAccount",
            placeholder: L10n.Settings.credentialCenterNewAccountPlaceholder,
            isSecure: false
        )
        configureCredentialCenterTextField(
            credentialCenterNewSecretField,
            identifier: "Stacio.Settings.credentialCenterNewSecret",
            placeholder: L10n.Settings.credentialCenterNewSecretPlaceholder,
            isSecure: true
        )
        credentialCenterAddPasswordButton.target = self
        credentialCenterAddPasswordButton.action = #selector(addCredentialCenterPasswordPressed(_:))
        credentialCenterAddPasswordButton.image = NSImage(
            systemSymbolName: "key.fill",
            accessibilityDescription: nil
        )
        credentialCenterAddPasswordButton.imagePosition = .imageLeading
        credentialCenterAddPasswordButton.setAccessibilityIdentifier("Stacio.Settings.credentialCenterAddPassword")
        credentialCenterAddPasswordButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSheetButton(credentialCenterAddPasswordButton)
        credentialCenterAddPrivateKeyPassphraseButton.target = self
        credentialCenterAddPrivateKeyPassphraseButton.action = #selector(addCredentialCenterPrivateKeyPassphrasePressed(_:))
        credentialCenterAddPrivateKeyPassphraseButton.image = NSImage(
            systemSymbolName: "key.horizontal",
            accessibilityDescription: nil
        )
        credentialCenterAddPrivateKeyPassphraseButton.imagePosition = .imageLeading
        credentialCenterAddPrivateKeyPassphraseButton.setAccessibilityIdentifier("Stacio.Settings.credentialCenterAddPrivateKeyPassphrase")
        credentialCenterAddPrivateKeyPassphraseButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSheetButton(credentialCenterAddPrivateKeyPassphraseButton)
        credentialCenterAddTokenButton.target = self
        credentialCenterAddTokenButton.action = #selector(addCredentialCenterTokenPressed(_:))
        credentialCenterAddTokenButton.image = NSImage(
            systemSymbolName: "number.square",
            accessibilityDescription: nil
        )
        credentialCenterAddTokenButton.imagePosition = .imageLeading
        credentialCenterAddTokenButton.setAccessibilityIdentifier("Stacio.Settings.credentialCenterAddToken")
        credentialCenterAddTokenButton.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSheetButton(credentialCenterAddTokenButton)
        updateCredentialCenterAddButtonState()

        credentialCenterSummaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        credentialCenterSummaryLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        credentialCenterSummaryLabel.lineBreakMode = .byWordWrapping
        credentialCenterSummaryLabel.maximumNumberOfLines = 2
        credentialCenterSummaryLabel.setAccessibilityIdentifier("Stacio.Settings.credentialCenterSummary")
        credentialCenterSummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        credentialCenterListPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let selectorRow = NSStackView(views: [
            credentialCenterListPopup,
            credentialCenterRefreshButton,
            credentialCenterDeleteButton
        ])
        selectorRow.orientation = .horizontal
        selectorRow.alignment = .centerY
        selectorRow.spacing = 8
        selectorRow.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [selectorRow, credentialCenterSummaryLabel])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actions.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth),
            selectorRow.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth),
            credentialCenterListPopup.heightAnchor.constraint(equalToConstant: 34),
            credentialCenterRefreshButton.widthAnchor.constraint(equalToConstant: 32),
            credentialCenterRefreshButton.heightAnchor.constraint(equalToConstant: 32),
            credentialCenterDeleteButton.widthAnchor.constraint(equalToConstant: 32),
            credentialCenterDeleteButton.heightAnchor.constraint(equalToConstant: 32),
            credentialCenterNewLabelField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth),
            credentialCenterNewAccountField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth),
            credentialCenterNewSecretField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth),
            credentialCenterAddPasswordButton.heightAnchor.constraint(equalToConstant: 30),
            credentialCenterAddPrivateKeyPassphraseButton.heightAnchor.constraint(equalToConstant: 30),
            credentialCenterAddTokenButton.heightAnchor.constraint(equalToConstant: 30),
            credentialCenterSummaryLabel.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth)
        ])

        let newCredentialForm = makeForm(rows: [
            (L10n.Settings.credentialCenterNewLabel, credentialCenterNewLabelField),
            (L10n.Settings.credentialCenterNewAccount, credentialCenterNewAccountField),
            (L10n.Settings.credentialCenterNewSecret, credentialCenterNewSecretField)
        ])
        let createRow = NSStackView(views: [
            credentialCenterAddPasswordButton,
            credentialCenterAddPrivateKeyPassphraseButton,
            credentialCenterAddTokenButton
        ])
        createRow.orientation = .horizontal
        createRow.alignment = .centerY
        createRow.distribution = .fillEqually
        createRow.spacing = 8
        createRow.translatesAutoresizingMaskIntoConstraints = false
        createRow.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth).isActive = true

        return makeSettingsGroup(
            title: L10n.Settings.credentialCenterGroupTitle,
            detail: L10n.Settings.credentialCenterGroupDescription,
            identifier: "Stacio.Settings.group.credentialCenter",
            content: [
                makeSettingsDetailBlock([
                    makeSettingsControlRow(
                        label: L10n.Settings.credentialCenterSavedCredentials,
                        control: actions,
                        rowIdentifier: "Stacio.Settings.credentialCenterSavedCredentialsRow",
                        labelIdentifier: "Stacio.Settings.credentialCenterSavedCredentialsLabel"
                    ),
                    makeControlColumnHelpLabel(
                        L10n.Settings.credentialCenterListHelp,
                        identifier: "Stacio.Settings.credentialCenterListHelp"
                    )
                ]),
                makeSettingsDetailBlock([
                    newCredentialForm,
                    makeControlColumnHelpLabel(
                        L10n.Settings.credentialCenterSecretHelp,
                        identifier: "Stacio.Settings.credentialCenterSecretHelp"
                    )
                ]),
                makeSettingsControlRow(
                    label: L10n.Settings.credentialCenterAddAs,
                    control: createRow,
                    rowIdentifier: "Stacio.Settings.credentialCenterAddActionsRow",
                    labelIdentifier: "Stacio.Settings.credentialCenterAddActionsLabel"
                ),
            ]
        )
    }

    private func makeSessionPolicyGroup() -> NSView {
        let overrideSummary = makeHelpLabel(
            L10n.Settings.sessionPolicyOverrideSummary,
            identifier: "Stacio.Settings.sessionPolicyOverrideSummary"
        )
        let entry = makeHelpLabel(
            L10n.Settings.sessionPolicyEntry,
            identifier: "Stacio.Settings.sessionPolicyEntry"
        )
        return makeSettingsGroup(
            title: L10n.Settings.sessionPolicyGroupTitle,
            detail: L10n.Settings.sessionPolicyGroupDescription,
            identifier: "Stacio.Settings.group.sessionPolicy",
            content: [
                overrideSummary,
                entry
            ]
        )
    }

    private func configureOperationalPathLabels() {
        let paths = try? StacioPaths()
        applicationSupportPathLabel.stringValue = paths?.applicationSupportDirectory.path
            ?? "~/Library/Application Support/Stacio"
        databasePathLabel.stringValue = paths?.databaseURL.path
            ?? "~/Library/Application Support/Stacio/Stacio.sqlite"
        logPathLabel.stringValue = StacioLogStore.shared.logFileURL.path

        configurePathLabel(
            applicationSupportPathLabel,
            identifier: "Stacio.Settings.path.applicationSupport"
        )
        configurePathLabel(
            databasePathLabel,
            identifier: "Stacio.Settings.path.database"
        )
        configurePathLabel(
            logPathLabel,
            identifier: "Stacio.Settings.path.log"
        )
    }

    private func configurePathLabel(_ label: NSTextField, identifier: String) {
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = StacioDesignSystem.theme.primaryTextColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.isSelectable = true
        label.setAccessibilityIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeCopyablePathRow(
        label: NSTextField,
        button: NSButton,
        identifier: String,
        action: Selector
    ) -> NSView {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: AppSettingsLayout.pathLabelWidth),
            button.heightAnchor.constraint(equalToConstant: 30)
        ])
        return row
    }

    private func makeGroupedSurface(identifier: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = 0
        container.layer?.borderWidth = 0
        container.setAccessibilityIdentifier(identifier)
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)
        return container
    }

    private func makeSettingsListSurface(identifier: String, rows: [NSView]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = AppSettingsLayout.settingsListCornerRadius
        container.layer?.cornerCurve = .continuous
        StacioDesignSystem.setLayerBackgroundColor(
            container,
            color: StacioDesignSystem.dynamicColor(
                .unemphasizedSelectedContentBackgroundColor,
                alpha: 0.58
            )
        )
        container.layer?.borderWidth = 0
        container.setAccessibilityIdentifier(identifier)
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)

        let stackItems = rows.enumerated().flatMap { index, row -> [NSView] in
            if index == 0 {
                return [row]
            }
            return [makeSettingsRowSeparator(), row]
        }
        let stack = NSStackView(views: stackItems)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: AppSettingsLayout.groupWidth),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: AppSettingsLayout.settingsListHorizontalInset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -AppSettingsLayout.settingsListHorizontalInset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: AppSettingsLayout.settingsListVerticalInset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -AppSettingsLayout.settingsListVerticalInset)
        ])
        return container
    }

    private func makeSettingsRowSeparator() -> NSView {
        let separator = NSView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(
            separator,
            color: StacioDesignSystem.theme.separatorColor.withAlphaComponent(0.13)
        )
        separator.setAccessibilityIdentifier("Stacio.Settings.groupRowSeparator")
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 1)
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(
                equalToConstant: AppSettingsLayout.settingsListContentWidth
                    - AppSettingsLayout.settingsListSeparatorInset
            ),
            separator.heightAnchor.constraint(equalToConstant: 1 / scale)
        ])
        return separator
    }

    private func makeGroupSeparator() -> NSBox {
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.setAccessibilityIdentifier("Stacio.Settings.groupSeparator")
        return separator
    }

    private func makeGroupTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = StacioDesignSystem.theme.primaryTextColor
        return label
    }

    private func makeGroupDetailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = StacioDesignSystem.theme.secondaryTextColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.readableTextWidth)
        ])
        return label
    }

    private func makeSummaryRow(symbolName: String, label: NSTextField) -> NSView {
        let symbol = NSImageView(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 14, height: 14))
        )
        symbol.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [symbol, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 15),
            symbol.heightAnchor.constraint(equalToConstant: 15)
        ])
        return row
    }

    private func configureSummaryLabel(_ label: NSTextField, identifier: String) {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = StacioDesignSystem.theme.primaryTextColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityIdentifier(identifier)
    }

    private func makeTerminalThemeImportRow() -> NSView {
        refreshCustomTerminalThemeLabel()
        customTerminalThemeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        customTerminalThemeLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        customTerminalThemeLabel.lineBreakMode = .byTruncatingMiddle
        customTerminalThemeLabel.maximumNumberOfLines = 1
        customTerminalThemeLabel.setAccessibilityIdentifier("Stacio.Settings.customTerminalThemeSummary")
        customTerminalThemeLabel.translatesAutoresizingMaskIntoConstraints = false

        importTerminalThemeButton.target = self
        importTerminalThemeButton.action = #selector(importTerminalThemePressed(_:))
        importTerminalThemeButton.bezelStyle = .rounded
        importTerminalThemeButton.setAccessibilityIdentifier("Stacio.Settings.importTerminalTheme")
        importTerminalThemeButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [importTerminalThemeButton, customTerminalThemeLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            importTerminalThemeButton.heightAnchor.constraint(equalToConstant: 30),
            customTerminalThemeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460)
        ])
        return row
    }

    private func makeTerminalThemeGallery() -> NSView {
        terminalThemeCardButtons.removeAll()
        terminalThemeCardCheckmarks.removeAll()

        let cards = [makeSystemAdaptiveThemeCard()]
            + TerminalColorTheme.builtInThemes.map { makeTerminalThemeCard(theme: $0) }
        let stack = NSStackView(views: cards)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("Stacio.Settings.terminalThemeGallery")
        return stack
    }

    private func makeSystemAdaptiveThemeCard() -> NSButton {
        let selected = settingsStore.snapshot().terminalTheme == .system
        let button = makeThemeCardShell(
            id: TerminalThemeGalleryItemID.systemAdaptive,
            title: L10n.Settings.terminalThemeSystemAdaptiveName,
            selected: selected,
            action: #selector(systemAdaptiveThemeCardPressed(_:))
        )

        let content = makeSystemAdaptiveThemeCardContent(selected: selected)
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: button.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -12)
        ])
        terminalThemeCardButtons[TerminalThemeGalleryItemID.systemAdaptive] = button
        return button
    }

    private func makeTerminalThemeCard(theme: TerminalColorTheme) -> NSButton {
        let snapshot = settingsStore.snapshot()
        let selected = snapshot.terminalTheme == .dark && snapshot.terminalBuiltInThemeID == theme.id
        let id = theme.id ?? theme.name
        let button = makeThemeCardShell(
            id: id,
            title: theme.name,
            selected: selected,
            action: #selector(terminalThemeCardPressed(_:))
        )

        let content = makeTerminalThemeCardContent(theme: theme, selected: selected)
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: button.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -12)
        ])
        if let id = theme.id {
            terminalThemeCardButtons[id] = button
        }
        return button
    }

    private func makeThemeCardShell(id: String, title: String, selected: Bool, action: Selector) -> NSButton {
        let button = NSButton()
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .noImage
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityIdentifier("Stacio.Settings.themeCard.\(id)")
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(button, color: StacioDesignSystem.theme.controlBackgroundColor)
        button.layer?.cornerRadius = 8
        button.layer?.cornerCurve = .continuous
        button.layer?.borderWidth = selected ? 2 : 1
        button.layer?.borderColor = (selected ? StacioDesignSystem.theme.accentColor : StacioDesignSystem.theme.separatorColor).cgColor
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemeCardWidth),
            button.heightAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemeCardHeight)
        ])
        return button
    }

    private func makeSystemAdaptiveThemeCardContent(selected: Bool) -> NSView {
        let title = NSTextField(labelWithString: L10n.Settings.terminalThemeSystemAdaptiveName)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.lineBreakMode = .byTruncatingTail

        let source = NSTextField(labelWithString: L10n.Settings.terminalThemeSystemAdaptiveSource)
        source.font = .systemFont(ofSize: 11)
        source.textColor = StacioDesignSystem.theme.secondaryTextColor

        let header = NSStackView(views: [title, source])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        source.setContentHuggingPriority(.required, for: .horizontal)

        let sample = makeSystemAdaptiveTerminalSample(compact: true)
        sample.setAccessibilityIdentifier("Stacio.Settings.themeCard.\(TerminalThemeGalleryItemID.systemAdaptive).preview")

        let palette = makeSystemAdaptivePaletteStrip()
        palette.setAccessibilityIdentifier("Stacio.Settings.themeCard.\(TerminalThemeGalleryItemID.systemAdaptive).palette")

        let metadata = NSTextField(labelWithString: L10n.Settings.terminalThemeSystemAdaptiveMetadata)
        metadata.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metadata.textColor = StacioDesignSystem.theme.secondaryTextColor
        metadata.lineBreakMode = .byWordWrapping
        metadata.maximumNumberOfLines = 2
        metadata.setAccessibilityIdentifier("Stacio.Settings.themeCard.\(TerminalThemeGalleryItemID.systemAdaptive).metadata")

        let detailStack = NSStackView(views: [header, metadata, palette])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 9
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView(
            image: NSImage(
                systemSymbolName: "checkmark.circle.fill",
                accessibilityDescription: L10n.Settings.terminalThemeSystemAdaptiveName
            ) ?? NSImage()
        )
        check.contentTintColor = StacioDesignSystem.theme.accentColor
        check.alphaValue = selected ? 1 : 0
        check.translatesAutoresizingMaskIntoConstraints = false

        let detailAndCheck = NSStackView(views: [detailStack, check])
        detailAndCheck.orientation = .horizontal
        detailAndCheck.alignment = .top
        detailAndCheck.spacing = 10
        detailAndCheck.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [sample, detailAndCheck])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sample.widthAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemePreviewWidth),
            sample.heightAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemePreviewHeight),
            detailStack.widthAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemeCardWidth - AppSettingsLayout.terminalThemePreviewWidth - 72),
            palette.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            palette.heightAnchor.constraint(equalToConstant: 12),
            check.widthAnchor.constraint(equalToConstant: 18),
            check.heightAnchor.constraint(equalToConstant: 18)
        ])

        terminalThemeCardCheckmarks[TerminalThemeGalleryItemID.systemAdaptive] = check
        return stack
    }

    private func makeTerminalThemeCardContent(theme: TerminalColorTheme, selected: Bool) -> NSView {
        let title = NSTextField(labelWithString: theme.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = StacioDesignSystem.theme.primaryTextColor
        title.lineBreakMode = .byTruncatingTail

        let source = NSTextField(labelWithString: theme.sourceFormat.displayName)
        source.font = .systemFont(ofSize: 11)
        source.textColor = StacioDesignSystem.theme.secondaryTextColor

        let header = NSStackView(views: [title, source])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        source.setContentHuggingPriority(.required, for: .horizontal)

        let sample = makeThemeTerminalSample(theme: theme, compact: true)
        sample.setAccessibilityIdentifier("Stacio.Settings.themeCard.\(theme.id ?? theme.name).preview")

        let palette = makeThemePaletteStrip(theme: theme)
        palette.setAccessibilityIdentifier("Stacio.Settings.themeCard.\(theme.id ?? theme.name).palette")

        let metadata = NSTextField(labelWithString: themeMetadataText(theme))
        metadata.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metadata.textColor = StacioDesignSystem.theme.secondaryTextColor
        metadata.lineBreakMode = .byWordWrapping
        metadata.maximumNumberOfLines = 2
        metadata.setAccessibilityIdentifier("Stacio.Settings.themeCard.\(theme.id ?? theme.name).metadata")

        let detailStack = NSStackView(views: [header, metadata, palette])
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 9
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: theme.name) ?? NSImage())
        check.contentTintColor = StacioDesignSystem.theme.accentColor
        check.alphaValue = selected ? 1 : 0
        check.translatesAutoresizingMaskIntoConstraints = false

        let detailAndCheck = NSStackView(views: [detailStack, check])
        detailAndCheck.orientation = .horizontal
        detailAndCheck.alignment = .top
        detailAndCheck.spacing = 10
        detailAndCheck.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [sample, detailAndCheck])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sample.widthAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemePreviewWidth),
            sample.heightAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemePreviewHeight),
            detailStack.widthAnchor.constraint(equalToConstant: AppSettingsLayout.terminalThemeCardWidth - AppSettingsLayout.terminalThemePreviewWidth - 72),
            palette.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            palette.heightAnchor.constraint(equalToConstant: 12),
            check.widthAnchor.constraint(equalToConstant: 18),
            check.heightAnchor.constraint(equalToConstant: 18)
        ])

        if let id = theme.id {
            terminalThemeCardCheckmarks[id] = check
        }
        return stack
    }

    private func makeThemeTerminalSample(theme: TerminalColorTheme, compact: Bool) -> NSView {
        let sample = NSView()
        sample.wantsLayer = true
        sample.translatesAutoresizingMaskIntoConstraints = false
        sample.layer?.backgroundColor = theme.backgroundColor.cgColor
        sample.layer?.cornerRadius = compact ? 6 : 8
        sample.layer?.cornerCurve = .continuous

        let lines: [(String, NSColor)] = compact
            ? [
                ("root@stacio$ ls", theme.ansiColor(at: 2, fallback: theme.foregroundColor)),
                ("drwxr-xr-x 1 root boot", theme.ansiColor(at: 4, fallback: theme.foregroundColor)),
                ("-rw-r--r-- 1 root config.yaml", theme.foregroundColor),
                ("systemctl status nginx", theme.ansiColor(at: 3, fallback: theme.foregroundColor))
            ]
            : [
                ("root@stacio:~$ systemctl status nginx", theme.ansiColor(at: 2, fallback: theme.foregroundColor)),
                ("active (running)  pid 1842  /usr/sbin/nginx", theme.ansiColor(at: 3, fallback: theme.foregroundColor)),
                ("drwxr-xr-x  deploy  /srv/app", theme.ansiColor(at: 4, fallback: theme.foregroundColor)),
                ("root@stacio:~$ tail -f /var/log/app.log", theme.foregroundColor)
            ]
        let lineFields = lines.map { text, color -> NSTextField in
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedSystemFont(ofSize: compact ? 11 : 13, weight: .regular)
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            return label
        }
        let stack = NSStackView(views: lineFields)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = compact ? 3 : 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        sample.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sample.leadingAnchor, constant: compact ? 10 : 14),
            stack.trailingAnchor.constraint(equalTo: sample.trailingAnchor, constant: compact ? -10 : -14),
            stack.topAnchor.constraint(equalTo: sample.topAnchor, constant: compact ? 8 : 14),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: sample.bottomAnchor, constant: compact ? -8 : -14)
        ])
        return sample
    }

    private func makeSystemAdaptiveTerminalSample(compact: Bool) -> NSView {
        let sample = NSView()
        sample.wantsLayer = true
        sample.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.setLayerBackgroundColor(sample, color: NSColor.textBackgroundColor)
        sample.layer?.cornerRadius = 6
        sample.layer?.borderWidth = 1
        sample.layer?.borderColor = StacioDesignSystem.theme.separatorColor.cgColor

        let lightPane = makeAdaptiveSamplePane(
            title: "Light",
            background: .textBackgroundColor,
            foreground: .textColor
        )
        let darkPane = makeAdaptiveSamplePane(
            title: "Dark",
            background: TerminalColorTheme.portDeskDark.backgroundColor,
            foreground: TerminalColorTheme.portDeskDark.foregroundColor
        )

        let stack = NSStackView(views: [lightPane, darkPane])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        sample.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sample.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: sample.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: sample.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: sample.bottomAnchor, constant: -8)
        ])
        return sample
    }

    private func makeAdaptiveSamplePane(title: String, background: NSColor, foreground: NSColor) -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = background.cgColor
        pane.layer?.cornerRadius = 5
        pane.layer?.borderWidth = 1
        pane.layer?.borderColor = StacioDesignSystem.theme.separatorColor.cgColor
        pane.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = foreground.withAlphaComponent(0.7)
        titleLabel.maximumNumberOfLines = 1

        let sampleLabel = NSTextField(labelWithString: "root@pd$ ls\nsystemctl status")
        sampleLabel.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        sampleLabel.textColor = foreground
        sampleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [titleLabel, sampleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: pane.centerYAnchor)
        ])
        return pane
    }

    private func makeSystemAdaptivePaletteStrip() -> NSStackView {
        let colors: [NSColor] = [
            .textBackgroundColor,
            .textColor,
            .selectedTextBackgroundColor,
            TerminalColorTheme.portDeskDark.backgroundColor,
            TerminalColorTheme.portDeskDark.foregroundColor,
            TerminalColorTheme.portDeskDark.selectionBackgroundColor ?? .selectedTextBackgroundColor
        ]
        let swatches = colors.enumerated().map { index, color -> NSView in
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.layer?.cornerRadius = 3
            swatch.layer?.borderWidth = 1
            swatch.layer?.borderColor = StacioDesignSystem.theme.separatorColor.cgColor
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.setAccessibilityIdentifier("Stacio.Settings.systemAdaptivePalette.\(index)")
            return swatch
        }

        let stack = NSStackView(views: swatches)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func themeMetadataText(_ theme: TerminalColorTheme) -> String {
        let cursor = theme.cursorHex ?? theme.foregroundHex
        let selection = theme.selectionBackgroundHex ?? "#264F78"
        return "前景 \(theme.foregroundHex)   背景 \(theme.backgroundHex)\n光标 \(cursor)   选区 \(selection)"
    }

    private func makeThemePaletteStrip(theme: TerminalColorTheme) -> NSStackView {
        let swatches = theme.ansiColorHexes.enumerated().map { index, hex -> NSView in
            let swatch = NSView()
            swatch.wantsLayer = true
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.layer?.backgroundColor = (TerminalThemeColor.nsColor(from: hex) ?? .black).cgColor
            swatch.layer?.cornerRadius = 2
            swatch.setAccessibilityIdentifier("Stacio.Settings.themePalette.\(index)")
            return swatch
        }
        let stack = NSStackView(views: swatches)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeForm(rows: [(String, NSView)]) -> NSStackView {
        let formRows = rows.enumerated().flatMap { index, row -> [NSView] in
            let formRow = makeFormRow(label: row.0, control: row.1)
            if index == 0 {
                return [formRow]
            }
            return [makeSettingsRowSeparator(), formRow]
        }
        let stack = NSStackView(views: formRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setAccessibilityIdentifier("Stacio.Settings.formGrid")
        return stack
    }

    private func makeFormRow(label text: String, control: NSView) -> NSView {
        let identifier = formIdentifier(for: text)
        return makeSettingsControlRow(
            label: text,
            control: control,
            rowIdentifier: identifier.map { "Stacio.Settings.formRow.\($0)" },
            labelIdentifier: identifier.map { "Stacio.Settings.formLabel.\($0)" }
        )
    }

    private func makeSettingsControlRow(
        label text: String,
        control: NSView,
        rowIdentifier: String?,
        labelIdentifier: String?
    ) -> NSView {
        let label = makeFormLabel(text)
        label.setAccessibilityIdentifier(labelIdentifier)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, spacer, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier(rowIdentifier)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: AppSettingsLayout.settingsListContentWidth),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.settingsControlRowMinHeight),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        return row
    }

    private func makeFormLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = StacioDesignSystem.theme.primaryTextColor
        label.font = .systemFont(ofSize: 13)
        label.alignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        let cell = AppSettingsCenteredLabelCell(textCell: text)
        cell.font = label.font
        cell.textColor = label.textColor
        cell.alignment = label.alignment
        label.cell = cell
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: AppSettingsLayout.labelColumnWidth),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 34)
        ])
        return label
    }

    private func formIdentifier(for label: String) -> String? {
        switch label {
        case L10n.Settings.terminalFontFamily:
            return "terminalFontFamily"
        case L10n.Settings.fontSize:
            return "fontSize"
        case L10n.Settings.sessionTabIconMode:
            return "sessionTabIconMode"
        case L10n.Settings.terminalHighlightLevel:
            return "terminalHighlightLevel"
        case L10n.Settings.terminalCursorStyle:
            return "terminalCursorStyle"
        case L10n.Settings.terminalRightClickBehavior:
            return "terminalRightClickBehavior"
        case L10n.Settings.terminalCommandSuggestionHistoryMinLength:
            return "terminalCommandSuggestionHistoryMinLength"
        case L10n.Settings.terminalCommandSuggestionHistoryMaxLength:
            return "terminalCommandSuggestionHistoryMaxLength"
        case L10n.Settings.terminalCommandSuggestionWordSeparators:
            return "terminalCommandSuggestionWordSeparators"
        case L10n.Settings.terminalDuplicateSessionCommandDelay:
            return "terminalDuplicateSessionCommandDelayMilliseconds"
        case L10n.Settings.theme:
            return "theme"
        case L10n.Settings.terminalHighlightTheme:
            return "terminalHighlightTheme"
        case L10n.Settings.provider:
            return "provider"
        case L10n.Settings.baseURL:
            return "baseURL"
        case L10n.Settings.model:
            return "model"
        case L10n.Settings.apiKey:
            return "apiKey"
        case L10n.Settings.aiMaxRetryCount:
            return "aiMaxRetryCount"
        case L10n.Settings.aiRequestTimeoutSeconds:
            return "aiRequestTimeoutSeconds"
        case L10n.Settings.aiUserAgent:
            return "aiUserAgent"
        case L10n.Settings.confirmationPolicy:
            return "confirmationPolicy"
        case L10n.Settings.executionMode:
            return "executionMode"
        case L10n.Settings.agentCommandAllowPatterns:
            return "agentCommandAllowPatterns"
        case L10n.Settings.agentCommandDenyPatterns:
            return "agentCommandDenyPatterns"
        case L10n.Settings.aiContextCharacterLimit:
            return "aiContextCharacterLimit"
        case L10n.Settings.diagnosticsAuditExportLimit:
            return "diagnosticsAuditExportLimit"
        case L10n.Settings.diagnosticsAppLogLineLimit:
            return "diagnosticsAppLogLineLimit"
        case L10n.Settings.agentBridgeSocket:
            return "agentBridgeSocket"
        case L10n.Settings.aiModelCatalog:
            return "aiModelCatalog"
        case L10n.Settings.aiReasoningEffort:
            return "aiReasoningEffort"
        case L10n.Settings.aiCompatibilityProtocol:
            return "aiCompatibilityProtocol"
        case L10n.Settings.applicationSupport:
            return "applicationSupport"
        case L10n.Settings.database:
            return "database"
        case L10n.Settings.appLog:
            return "appLog"
        case L10n.Settings.credentialCenterNewLabel:
            return "credentialCenterNewLabel"
        case L10n.Settings.credentialCenterNewAccount:
            return "credentialCenterNewAccount"
        case L10n.Settings.credentialCenterNewSecret:
            return "credentialCenterNewSecret"
        default:
            return nil
        }
    }

    private func configureCustomThemeField(_ field: NSTextField, identifier: String, action: Selector) {
        field.target = self
        field.action = action
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        styleSettingsTextField(field)
    }

    private func configureCredentialCenterTextField(
        _ field: NSTextField,
        identifier: String,
        placeholder: String,
        isSecure: Bool
    ) {
        field.target = self
        field.action = #selector(credentialCenterInputChanged(_:))
        field.delegate = self
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        styleSettingsTextField(field)
        if isSecure {
            field.toolTip = L10n.Settings.credentialCenterNewSecretPlaceholder
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === terminalFontFamilyPopup.menu else { return }
        rebuildTerminalFontMenu()
    }

    private func rebuildTerminalFontMenu() {
        let snapshot = settingsStore.snapshot()
        terminalFontFamilyPopup.removeAllItems()
        for fontFamily in TerminalFontFamilyPreference.allCases {
            addTerminalFontItem(
                title: fontFamily.displayName,
                representedObject: "preset:\(fontFamily.rawValue)"
            )
        }
        let presetTitles = Set(TerminalFontFamilyPreference.allCases.map(\.displayName))
        let installedFamilies = TerminalFontCatalog.installedFamilyNames().filter { !presetTitles.contains($0) }
        let monospacedFamilies = Set(installedFamilies.filter(TerminalFontCatalog.isMonospacedFamily(named:)))
        for monospaced in [true, false] {
            let families = installedFamilies.filter { monospacedFamilies.contains($0) == monospaced }
            guard !families.isEmpty else { continue }
            terminalFontFamilyPopup.menu?.addItem(.separator())
            for family in families {
                addTerminalFontItem(title: family, representedObject: "custom:\(family)")
            }
        }
        if snapshot.terminalFontFamily == .system,
           let customFontName = snapshot.terminalCustomFontName,
           terminalFontFamilyPopup.itemTitles.contains(customFontName) == false {
            addTerminalFontItem(title: customFontName, representedObject: "custom:\(customFontName)")
        }
        terminalFontFamilyPopup.selectItem(withTitle: title(
            for: snapshot.terminalFontFamily,
            customFontName: snapshot.terminalCustomFontName
        ))
    }

    private func configureTerminalControls() {
        let snapshot = settingsStore.snapshot()
        terminalFontFamilyPopup.selectItem(withTitle: title(
            for: snapshot.terminalFontFamily,
            customFontName: snapshot.terminalCustomFontName
        ))
        fontSizeField.stringValue = "\(Int(snapshot.terminalFontSize))"
        themeControl.selectedSegment = segment(for: snapshot.terminalTheme)
        sessionTabIconModeControl.selectedSegment = segment(for: snapshot.sessionTabIconMode)
        sessionSidebarShowRecentSessionsButton.state = snapshot.sessionSidebarShowRecentSessions ? .on : .off
        terminalHighlightThemePopup.selectItem(withTitle: title(forBuiltInThemeID: snapshot.terminalBuiltInThemeID))
        terminalHighlightLevelControl.selectedSegment = segment(for: snapshot.terminalHighlightLevel)
        terminalRichHighlightingButton.state = snapshot.terminalRichHighlightingEnabled ? .on : .off
        terminalCursorStyleControl.selectedSegment = segment(for: snapshot.terminalCursorShape)
        terminalCursorBlinkButton.state = snapshot.terminalCursorBlinkEnabled ? .on : .off
        terminalCloseConfirmationButton.state = snapshot.terminalCloseConfirmationEnabled ? .on : .off
        terminalSelectionAutoCopyButton.state = snapshot.terminalSelectionAutoCopyEnabled ? .on : .off
        terminalRightClickControl.selectedSegment = segment(for: snapshot.terminalRightClickBehavior)
        terminalControlScrollZoomButton.state = snapshot.terminalControlScrollZoomEnabled ? .on : .off
        terminalScrollbackLinesField.stringValue = "\(snapshot.terminalScrollbackLines)"
        terminalKeepAliveIntervalSecondsField.stringValue = "\(snapshot.terminalKeepAliveIntervalSeconds)"
        terminalX11DisplayField.stringValue = snapshot.terminalX11Display
        terminalHardwareAccelerationButton.state = snapshot.terminalHardwareAccelerationEnabled ? .on : .off
        terminalWorkspacePaddingButton.state = snapshot.terminalWorkspacePaddingEnabled ? .on : .off
        terminalLineNumbersButton.state = snapshot.terminalLineNumbersEnabled ? .on : .off
        terminalTimestampsButton.state = snapshot.terminalTimestampsEnabled ? .on : .off
        terminalTimestampMillisecondsButton.state = snapshot.terminalTimestampMillisecondsEnabled ? .on : .off
        terminalMultiLinePasteConfirmationButton.state = snapshot.terminalMultiLinePasteConfirmationEnabled ? .on : .off
        terminalPasteImageAsPathButton.state = snapshot.terminalPasteImageAsPathEnabled ? .on : .off
        terminalAltAsMetaButton.state = snapshot.terminalAltAsMetaEnabled ? .on : .off
        terminalMacIMECompatibilityButton.state = snapshot.terminalMacIMECompatibilityEnabled ? .on : .off
        terminalCommandSuggestionButton.state = snapshot.terminalCommandSuggestionEnabled ? .on : .off
        terminalCommandSuggestionHistoryMinLengthField.stringValue = "\(snapshot.terminalCommandSuggestionHistoryMinLength)"
        terminalCommandSuggestionHistoryMaxLengthField.stringValue = "\(snapshot.terminalCommandSuggestionHistoryMaxLength)"
        terminalCommandSuggestionWordSeparatorsField.stringValue = snapshot.terminalCommandSuggestionWordSeparators
        terminalDuplicateSessionCommandDelayMillisecondsField.stringValue = "\(snapshot.terminalDuplicateSessionCommandDelayMilliseconds)"
        terminalCommandCompletionNotificationButton.state = snapshot.terminalCommandCompletionNotificationEnabled ? .on : .off
        terminalCommandCompletionNotificationThresholdSecondsField.stringValue = "\(snapshot.terminalCommandCompletionNotificationThresholdSeconds)"
        terminalAutomaticReconnectButton.state = snapshot.terminalAutomaticReconnectEnabled ? .on : .off
        terminalAutomaticReconnectIntervalField.stringValue = "\(snapshot.terminalAutomaticReconnectIntervalSeconds)"
        terminalAutomaticReconnectAttemptsField.stringValue = "\(snapshot.terminalAutomaticReconnectAttempts)"

        guard terminalControlsConfigured == false else {
            return
        }
        terminalControlsConfigured = true
        rebuildTerminalFontMenu()
        terminalFontFamilyPopup.menu?.delegate = self
        terminalFontFamilyPopup.toolTip = "可选择本机安装的字体；等宽字体更适合终端表格和字符画对齐。"
        terminalFontFamilyPopup.target = self
        terminalFontFamilyPopup.action = #selector(terminalFontFamilyChanged(_:))
        terminalFontFamilyPopup.setAccessibilityIdentifier("Stacio.Settings.terminalFontFamily")
        StacioDesignSystem.stylePopupButton(terminalFontFamilyPopup)

        terminalHighlightThemePopup.removeAllItems()
        terminalHighlightThemePopup.addItems(withTitles: TerminalColorTheme.builtInThemes.map(\.name))
        terminalHighlightThemePopup.selectItem(withTitle: title(forBuiltInThemeID: snapshot.terminalBuiltInThemeID))
        terminalHighlightThemePopup.target = self
        terminalHighlightThemePopup.action = #selector(terminalHighlightThemeChanged(_:))
        terminalHighlightThemePopup.setAccessibilityIdentifier("Stacio.Settings.terminalHighlightTheme")
        StacioDesignSystem.stylePopupButton(terminalHighlightThemePopup)

        terminalHighlightLevelControl.target = self
        terminalHighlightLevelControl.action = #selector(terminalHighlightLevelChanged(_:))
        terminalHighlightLevelControl.setAccessibilityIdentifier("Stacio.Settings.terminalHighlightLevel")
        StacioDesignSystem.styleSegmentedControl(terminalHighlightLevelControl)

        terminalRichHighlightingButton.target = self
        terminalRichHighlightingButton.action = #selector(terminalRichHighlightingChanged(_:))
        terminalRichHighlightingButton.setAccessibilityIdentifier("Stacio.Settings.terminalRichHighlighting")
        terminalRichHighlightingButton.setAccessibilityLabel(L10n.Settings.terminalRichHighlighting)
        terminalRichHighlightingButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalRichHighlightingButton.translatesAutoresizingMaskIntoConstraints = false

        fontSizeField.alignment = .right
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeChanged(_:))
        fontSizeField.setAccessibilityIdentifier("Stacio.Settings.fontSize")
        styleSettingsTextField(fontSizeField)

        themeControl.target = self
        themeControl.action = #selector(themeChanged(_:))
        themeControl.setAccessibilityIdentifier("Stacio.Settings.theme")
        StacioDesignSystem.styleSegmentedControl(themeControl)

        sessionTabIconModeControl.target = self
        sessionTabIconModeControl.action = #selector(sessionTabIconModeChanged(_:))
        sessionTabIconModeControl.setAccessibilityIdentifier("Stacio.Settings.sessionTabIconMode")
        StacioDesignSystem.styleSegmentedControl(sessionTabIconModeControl)

        configureTerminalCheckbox(
            sessionSidebarShowRecentSessionsButton,
            action: #selector(sessionSidebarShowRecentSessionsChanged(_:)),
            identifier: "Stacio.Settings.sessionSidebarShowRecentSessions"
        )

        terminalCursorStyleControl.target = self
        terminalCursorStyleControl.action = #selector(terminalCursorStyleChanged(_:))
        terminalCursorStyleControl.setAccessibilityIdentifier("Stacio.Settings.terminalCursorStyle")
        StacioDesignSystem.styleSegmentedControl(terminalCursorStyleControl)

        terminalCursorBlinkButton.target = self
        terminalCursorBlinkButton.action = #selector(terminalCursorBlinkChanged(_:))
        terminalCursorBlinkButton.setAccessibilityIdentifier("Stacio.Settings.terminalCursorBlink")
        terminalCursorBlinkButton.setAccessibilityLabel(L10n.Settings.terminalCursorBlink)
        terminalCursorBlinkButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalCursorBlinkButton.translatesAutoresizingMaskIntoConstraints = false

        terminalCloseConfirmationButton.target = self
        terminalCloseConfirmationButton.action = #selector(terminalCloseConfirmationChanged(_:))
        terminalCloseConfirmationButton.setAccessibilityIdentifier("Stacio.Settings.terminalCloseConfirmation")
        terminalCloseConfirmationButton.setAccessibilityLabel(L10n.Settings.terminalCloseConfirmation)
        terminalCloseConfirmationButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalCloseConfirmationButton.translatesAutoresizingMaskIntoConstraints = false

        terminalSelectionAutoCopyButton.target = self
        terminalSelectionAutoCopyButton.action = #selector(terminalSelectionAutoCopyChanged(_:))
        terminalSelectionAutoCopyButton.setAccessibilityIdentifier("Stacio.Settings.terminalSelectionAutoCopy")
        terminalSelectionAutoCopyButton.setAccessibilityLabel(L10n.Settings.terminalSelectionAutoCopy)
        terminalSelectionAutoCopyButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalSelectionAutoCopyButton.translatesAutoresizingMaskIntoConstraints = false

        terminalRightClickControl.target = self
        terminalRightClickControl.action = #selector(terminalRightClickBehaviorChanged(_:))
        terminalRightClickControl.setAccessibilityIdentifier("Stacio.Settings.terminalRightClickBehavior")
        StacioDesignSystem.styleSegmentedControl(terminalRightClickControl)

        terminalControlScrollZoomButton.target = self
        terminalControlScrollZoomButton.action = #selector(terminalControlScrollZoomChanged(_:))
        terminalControlScrollZoomButton.setAccessibilityIdentifier("Stacio.Settings.terminalControlScrollZoom")
        terminalControlScrollZoomButton.setAccessibilityLabel(L10n.Settings.terminalControlScrollZoom)
        terminalControlScrollZoomButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalControlScrollZoomButton.translatesAutoresizingMaskIntoConstraints = false

        configureNumericTerminalField(
            terminalScrollbackLinesField,
            action: #selector(terminalScrollbackLinesChanged(_:)),
            identifier: "Stacio.Settings.terminalScrollbackLines"
        )
        configureNumericTerminalField(
            terminalKeepAliveIntervalSecondsField,
            action: #selector(terminalKeepAliveIntervalSecondsChanged(_:)),
            identifier: "Stacio.Settings.terminalKeepAliveIntervalSeconds"
        )
        terminalX11DisplayField.target = self
        terminalX11DisplayField.action = #selector(terminalX11DisplayChanged(_:))
        terminalX11DisplayField.delegate = self
        terminalX11DisplayField.setAccessibilityIdentifier("Stacio.Settings.terminalX11Display")
        styleSettingsTextField(terminalX11DisplayField)

        configureTerminalCheckbox(terminalHardwareAccelerationButton, action: #selector(terminalHardwareAccelerationChanged(_:)), identifier: "Stacio.Settings.terminalHardwareAcceleration")
        configureTerminalCheckbox(terminalWorkspacePaddingButton, action: #selector(terminalWorkspacePaddingChanged(_:)), identifier: "Stacio.Settings.terminalWorkspacePadding")
        configureTerminalCheckbox(terminalLineNumbersButton, action: #selector(terminalLineNumbersChanged(_:)), identifier: "Stacio.Settings.terminalLineNumbers")
        configureTerminalCheckbox(terminalTimestampsButton, action: #selector(terminalTimestampsChanged(_:)), identifier: "Stacio.Settings.terminalTimestamps")
        configureTerminalCheckbox(terminalTimestampMillisecondsButton, action: #selector(terminalTimestampMillisecondsChanged(_:)), identifier: "Stacio.Settings.terminalTimestampMilliseconds")
        configureTerminalCheckbox(terminalMultiLinePasteConfirmationButton, action: #selector(terminalMultiLinePasteConfirmationChanged(_:)), identifier: "Stacio.Settings.terminalMultiLinePasteConfirmation")
        configureTerminalCheckbox(terminalPasteImageAsPathButton, action: #selector(terminalPasteImageAsPathChanged(_:)), identifier: "Stacio.Settings.terminalPasteImageAsPath")
        configureTerminalCheckbox(terminalAltAsMetaButton, action: #selector(terminalAltAsMetaChanged(_:)), identifier: "Stacio.Settings.terminalAltAsMeta")
        configureTerminalCheckbox(terminalMacIMECompatibilityButton, action: #selector(terminalMacIMECompatibilityChanged(_:)), identifier: "Stacio.Settings.terminalMacIMECompatibility")

        terminalCommandSuggestionButton.target = self
        terminalCommandSuggestionButton.action = #selector(terminalCommandSuggestionChanged(_:))
        terminalCommandSuggestionButton.setAccessibilityIdentifier("Stacio.Settings.terminalCommandSuggestionEnabled")
        terminalCommandSuggestionButton.setAccessibilityLabel(L10n.Settings.terminalCommandSuggestion)
        terminalCommandSuggestionButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalCommandSuggestionButton.translatesAutoresizingMaskIntoConstraints = false

        terminalFavoriteCommandsButton.target = self
        terminalFavoriteCommandsButton.action = #selector(manageTerminalFavoriteCommandsPressed(_:))
        terminalFavoriteCommandsButton.bezelStyle = .rounded
        terminalFavoriteCommandsButton.setAccessibilityIdentifier("Stacio.Settings.terminalFavoriteCommands")
        terminalFavoriteCommandsButton.translatesAutoresizingMaskIntoConstraints = false

        terminalCommandSuggestionHistoryMinLengthField.alignment = .right
        terminalCommandSuggestionHistoryMinLengthField.target = self
        terminalCommandSuggestionHistoryMinLengthField.action = #selector(terminalCommandSuggestionHistoryMinLengthChanged(_:))
        terminalCommandSuggestionHistoryMinLengthField.delegate = self
        terminalCommandSuggestionHistoryMinLengthField.setAccessibilityIdentifier("Stacio.Settings.terminalCommandSuggestionHistoryMinLength")
        styleSettingsTextField(terminalCommandSuggestionHistoryMinLengthField)

        terminalCommandSuggestionHistoryMaxLengthField.alignment = .right
        terminalCommandSuggestionHistoryMaxLengthField.target = self
        terminalCommandSuggestionHistoryMaxLengthField.action = #selector(terminalCommandSuggestionHistoryMaxLengthChanged(_:))
        terminalCommandSuggestionHistoryMaxLengthField.delegate = self
        terminalCommandSuggestionHistoryMaxLengthField.setAccessibilityIdentifier("Stacio.Settings.terminalCommandSuggestionHistoryMaxLength")
        styleSettingsTextField(terminalCommandSuggestionHistoryMaxLengthField)

        terminalCommandSuggestionWordSeparatorsField.target = self
        terminalCommandSuggestionWordSeparatorsField.action = #selector(terminalCommandSuggestionWordSeparatorsChanged(_:))
        terminalCommandSuggestionWordSeparatorsField.delegate = self
        terminalCommandSuggestionWordSeparatorsField.setAccessibilityIdentifier("Stacio.Settings.terminalCommandSuggestionWordSeparators")
        styleSettingsTextField(terminalCommandSuggestionWordSeparatorsField)

        terminalDuplicateSessionCommandDelayMillisecondsField.alignment = .right
        terminalDuplicateSessionCommandDelayMillisecondsField.target = self
        terminalDuplicateSessionCommandDelayMillisecondsField.action = #selector(terminalDuplicateSessionCommandDelayMillisecondsChanged(_:))
        terminalDuplicateSessionCommandDelayMillisecondsField.delegate = self
        terminalDuplicateSessionCommandDelayMillisecondsField.setAccessibilityIdentifier("Stacio.Settings.terminalDuplicateSessionCommandDelayMilliseconds")
        styleSettingsTextField(terminalDuplicateSessionCommandDelayMillisecondsField)

        terminalCommandCompletionNotificationButton.target = self
        terminalCommandCompletionNotificationButton.action = #selector(terminalCommandCompletionNotificationChanged(_:))
        terminalCommandCompletionNotificationButton.setAccessibilityIdentifier("Stacio.Settings.terminalCommandCompletionNotificationEnabled")
        terminalCommandCompletionNotificationButton.setAccessibilityLabel(L10n.Settings.terminalCommandCompletionNotification)
        terminalCommandCompletionNotificationButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalCommandCompletionNotificationButton.translatesAutoresizingMaskIntoConstraints = false

        terminalCommandCompletionNotificationThresholdSecondsField.alignment = .right
        terminalCommandCompletionNotificationThresholdSecondsField.target = self
        terminalCommandCompletionNotificationThresholdSecondsField.action = #selector(terminalCommandCompletionNotificationThresholdSecondsChanged(_:))
        terminalCommandCompletionNotificationThresholdSecondsField.delegate = self
        terminalCommandCompletionNotificationThresholdSecondsField.setAccessibilityIdentifier("Stacio.Settings.terminalCommandCompletionNotificationThresholdSeconds")
        styleSettingsTextField(terminalCommandCompletionNotificationThresholdSecondsField)

        terminalAutomaticReconnectButton.target = self
        terminalAutomaticReconnectButton.action = #selector(terminalAutomaticReconnectChanged(_:))
        terminalAutomaticReconnectButton.setAccessibilityIdentifier("Stacio.Settings.terminalAutomaticReconnect")
        terminalAutomaticReconnectButton.setAccessibilityLabel(L10n.Settings.terminalAutomaticReconnect)
        terminalAutomaticReconnectButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        terminalAutomaticReconnectButton.translatesAutoresizingMaskIntoConstraints = false
        for (field, identifier) in [
            (terminalAutomaticReconnectIntervalField, "Stacio.Settings.terminalAutomaticReconnectInterval"),
            (terminalAutomaticReconnectAttemptsField, "Stacio.Settings.terminalAutomaticReconnectAttempts")
        ] {
            field.alignment = .right
            field.target = self
            field.delegate = self
            field.setAccessibilityIdentifier(identifier)
            styleSettingsTextField(field)
        }
        terminalAutomaticReconnectIntervalField.action = #selector(terminalAutomaticReconnectIntervalChanged(_:))
        terminalAutomaticReconnectAttemptsField.action = #selector(terminalAutomaticReconnectAttemptsChanged(_:))

        NSLayoutConstraint.activate([
            terminalFontFamilyPopup.widthAnchor.constraint(equalToConstant: AppSettingsLayout.popupWidth),
            terminalFontFamilyPopup.heightAnchor.constraint(equalToConstant: 34),
            terminalHighlightThemePopup.widthAnchor.constraint(equalToConstant: AppSettingsLayout.popupWidth),
            terminalHighlightThemePopup.heightAnchor.constraint(equalToConstant: 34),
            terminalHighlightLevelControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            terminalHighlightLevelControl.heightAnchor.constraint(equalToConstant: 32),
            terminalRichHighlightingButton.heightAnchor.constraint(equalToConstant: 28),
            fontSizeField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            fontSizeField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            themeControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            themeControl.heightAnchor.constraint(equalToConstant: 32),
            sessionTabIconModeControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            sessionTabIconModeControl.heightAnchor.constraint(equalToConstant: 32),
            sessionSidebarShowRecentSessionsButton.heightAnchor.constraint(equalToConstant: 28),
            terminalCursorStyleControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            terminalCursorStyleControl.heightAnchor.constraint(equalToConstant: 32),
            terminalCursorBlinkButton.heightAnchor.constraint(equalToConstant: 28),
            terminalCloseConfirmationButton.heightAnchor.constraint(equalToConstant: 28),
            terminalSelectionAutoCopyButton.heightAnchor.constraint(equalToConstant: 28),
            terminalRightClickControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            terminalRightClickControl.heightAnchor.constraint(equalToConstant: 32),
            terminalControlScrollZoomButton.heightAnchor.constraint(equalToConstant: 28),
            terminalScrollbackLinesField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalScrollbackLinesField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalKeepAliveIntervalSecondsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalKeepAliveIntervalSecondsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalX11DisplayField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.fieldWidth),
            terminalX11DisplayField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalHardwareAccelerationButton.heightAnchor.constraint(equalToConstant: 28),
            terminalWorkspacePaddingButton.heightAnchor.constraint(equalToConstant: 28),
            terminalLineNumbersButton.heightAnchor.constraint(equalToConstant: 28),
            terminalTimestampsButton.heightAnchor.constraint(equalToConstant: 28),
            terminalTimestampMillisecondsButton.heightAnchor.constraint(equalToConstant: 28),
            terminalMultiLinePasteConfirmationButton.heightAnchor.constraint(equalToConstant: 28),
            terminalPasteImageAsPathButton.heightAnchor.constraint(equalToConstant: 28),
            terminalAltAsMetaButton.heightAnchor.constraint(equalToConstant: 28),
            terminalMacIMECompatibilityButton.heightAnchor.constraint(equalToConstant: 28),
            terminalCommandSuggestionButton.heightAnchor.constraint(equalToConstant: 28),
            terminalFavoriteCommandsButton.heightAnchor.constraint(equalToConstant: 30),
            terminalCommandSuggestionHistoryMinLengthField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalCommandSuggestionHistoryMinLengthField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalCommandSuggestionHistoryMaxLengthField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalCommandSuggestionHistoryMaxLengthField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalCommandSuggestionWordSeparatorsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth),
            terminalCommandSuggestionWordSeparatorsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalDuplicateSessionCommandDelayMillisecondsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalDuplicateSessionCommandDelayMillisecondsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalCommandCompletionNotificationButton.heightAnchor.constraint(equalToConstant: 28),
            terminalCommandCompletionNotificationThresholdSecondsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalCommandCompletionNotificationThresholdSecondsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalAutomaticReconnectButton.heightAnchor.constraint(equalToConstant: 28),
            terminalAutomaticReconnectIntervalField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalAutomaticReconnectIntervalField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            terminalAutomaticReconnectAttemptsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            terminalAutomaticReconnectAttemptsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight)
        ])
    }

    private func configureNumericTerminalField(_ field: NSTextField, action: Selector, identifier: String) {
        field.alignment = .right
        field.target = self
        field.action = action
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        styleSettingsTextField(field)
    }

    private func styleSettingsTextField(_ field: NSTextField) {
        installSettingsTextFieldCellIfNeeded(field)
        field.wantsLayer = true
        StacioDesignSystem.setLayerBackgroundColor(
            field,
            color: StacioDesignSystem.dynamicColor(.textBackgroundColor, alpha: 0.68)
        )
        StacioDesignSystem.setLayerBorderColor(field, color: nil)
        field.layer?.borderWidth = 0
        field.layer?.cornerRadius = 6
        field.layer?.cornerCurve = .continuous
        field.layer?.masksToBounds = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .default
        field.textColor = StacioDesignSystem.theme.primaryTextColor
        field.controlSize = .regular
        field.cell?.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        field.cell?.font = field.font
    }

    private func installSettingsTextFieldCellIfNeeded(_ field: NSTextField) {
        if field.cell is AppSettingsInsetTextFieldCell || field.cell is AppSettingsInsetSecureTextFieldCell {
            return
        }

        let existingCell = field.cell as? NSTextFieldCell
        let currentValue = field.stringValue
        let placeholder = field.placeholderString
        let target = field.target
        let action = field.action
        let delegate = field.delegate
        let replacementCell: NSTextFieldCell = field is NSSecureTextField
            ? AppSettingsInsetSecureTextFieldCell(textCell: currentValue)
            : AppSettingsInsetTextFieldCell(textCell: currentValue)

        replacementCell.placeholderString = placeholder
        replacementCell.controlSize = .regular
        replacementCell.font = field.font ?? .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        replacementCell.alignment = existingCell?.alignment ?? field.alignment
        replacementCell.isEditable = existingCell?.isEditable ?? true
        replacementCell.isSelectable = existingCell?.isSelectable ?? true
        replacementCell.isBordered = false
        replacementCell.isBezeled = false
        replacementCell.drawsBackground = false
        replacementCell.lineBreakMode = existingCell?.lineBreakMode ?? .byTruncatingTail
        replacementCell.usesSingleLineMode = existingCell?.usesSingleLineMode ?? true
        replacementCell.wraps = existingCell?.wraps ?? false
        replacementCell.isScrollable = existingCell?.isScrollable ?? true

        field.cell = replacementCell
        field.target = target
        field.action = action
        field.delegate = delegate
    }

    private func configureTerminalCheckbox(_ button: NSButton, action: Selector, identifier: String) {
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(button.title)
        button.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureAIControls() {
        let snapshot = settingsStore.snapshot()
        let assistantSnapshot = try? AssistantRuntimeSettingsSnapshot.resolve(
            from: assistantSettingsValueStore
        )

        aiProviderPopup.selectItem(withTitle: title(forAIProvider: snapshot.aiProvider))
        aiBaseURLField.stringValue = snapshot.aiBaseURL
        aiModelField.stringValue = snapshot.aiModel
        aiAPIKeyField.stringValue = (try? aiAPIKeyStore.readAPIKey(
            for: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )) ?? ""
        aiMaxRetryCountField.stringValue = "\(snapshot.aiMaxRetryCount)"
        aiRequestTimeoutSecondsField.stringValue = "\(snapshot.aiRequestTimeoutSeconds)"
        aiUserAgentField.stringValue = snapshot.aiUserAgent
        refreshAIModelCatalogControls()
        refreshAIProviderFieldAvailability()
        aiIncludeRecentTerminalTranscriptButton.state = snapshot.aiIncludeRecentTerminalTranscript ? .on : .off
        aiContextCharacterLimitField.stringValue = "\(snapshot.aiContextCharacterLimit)"
        confirmationControl.selectedSegment = segment(for: snapshot.agentConfirmationPolicy)
        agentCommandAllowPatternsField.stringValue = snapshot.agentCommandAllowPatterns
        agentCommandDenyPatternsField.stringValue = snapshot.agentCommandDenyPatterns
        aiAutoRunProposedCommandsButton.state = snapshot.aiAutoRunProposedCommands ? .on : .off
        aiRestoreLastConversationButton.state = assistantSnapshot?.restoreLastConversationEnabled == false ? .off : .on
        aiSendKeyModeControl.selectedSegment = assistantSnapshot?.sendKeyMode == "commandReturn" ? 1 : 0
        switch assistantSnapshot?.terminalOutputMode ?? "boundedHeadTail" {
        case "summaryOnly": aiTerminalOutputModeControl.selectedSegment = 1
        case "excluded": aiTerminalOutputModeControl.selectedSegment = 2
        default: aiTerminalOutputModeControl.selectedSegment = 0
        }
        aiAutoCompressContextButton.state = assistantSnapshot?.automaticContextCompressionEnabled == false ? .off : .on
        switch assistantSnapshot?.defaultTerminalMode {
        case "backgroundVirtualTerminal":
            aiDefaultTerminalModeControl.selectedSegment = 1
        case "ask":
            aiDefaultTerminalModeControl.selectedSegment = 2
        default:
            aiDefaultTerminalModeControl.selectedSegment = 0
        }
        aiMaxToolStepsField.stringValue = "\(assistantSnapshot?.maxToolSteps ?? 40)"
        aiMaxModelInvocationsField.stringValue = "\(assistantSnapshot?.maxModelInvocations ?? 40)"
        aiMaxEffectiveMinutesField.stringValue = "\(assistantSnapshot?.maxEffectiveMinutes ?? 30)"
        aiHistoryRetentionDaysField.stringValue = "\(assistantSnapshot?.historyRetentionDays ?? 30)"
        switch assistantSnapshot?.terminalRecordingScope ?? "bounded" {
        case "none": aiTerminalRecordingScopeControl.selectedSegment = 0
        case "fullWhenAudited": aiTerminalRecordingScopeControl.selectedSegment = 2
        default: aiTerminalRecordingScopeControl.selectedSegment = 1
        }
        let assistantSettingsAvailable = assistantSettingsValueStore != nil
            && assistantSettingsMutationCoordinator != nil
            && assistantSnapshot != nil
        setAssistantSettingsControlsEnabled(assistantSettingsAvailable)
        if assistantSettingsAvailable == false {
            aiSessionSettingsStatusLabel.stringValue = L10n.Settings.aiAssistantSettingUnavailable
            aiContextSettingsStatusLabel.stringValue = L10n.Settings.aiAssistantSettingUnavailable
            aiExecutionSettingsStatusLabel.stringValue = L10n.Settings.aiAssistantSettingUnavailable
        }
        refreshAISummary()

        guard aiControlsConfigured == false else {
            return
        }
        aiControlsConfigured = true
        aiProviderPopup.removeAllItems()
        aiProviderPopup.addItems(withTitles: AIProviderProfile.settingsMenuProfiles.map(\.displayName))
        aiProviderPopup.selectItem(withTitle: title(forAIProvider: snapshot.aiProvider))
        aiProviderPopup.target = self
        aiProviderPopup.action = #selector(aiProviderChanged(_:))
        aiProviderPopup.setAccessibilityIdentifier("Stacio.Settings.aiProvider")
        StacioDesignSystem.stylePopupButton(aiProviderPopup)

        aiBaseURLField.placeholderString = "api.example.com/v1 或 localhost:11434/v1"
        aiBaseURLField.target = self
        aiBaseURLField.action = #selector(aiBaseURLChanged(_:))
        aiBaseURLField.delegate = self
        aiBaseURLField.setAccessibilityIdentifier("Stacio.Settings.aiBaseURL")
        styleSettingsTextField(aiBaseURLField)

        aiModelField.placeholderString = "从上游获取或手动添加"
        aiModelField.target = self
        aiModelField.action = #selector(aiModelChanged(_:))
        aiModelField.delegate = self
        aiModelField.setAccessibilityIdentifier("Stacio.Settings.aiModel")
        styleSettingsTextField(aiModelField)

        aiModelCatalogPopup.target = self
        aiModelCatalogPopup.action = #selector(aiModelCatalogChanged(_:))
        aiModelCatalogPopup.setAccessibilityIdentifier("Stacio.Settings.aiModelCatalog")
        StacioDesignSystem.stylePopupButton(aiModelCatalogPopup)

        configureAICustomModelList()

        aiRefreshModelsButton.target = self
        aiRefreshModelsButton.action = #selector(aiRefreshModelsPressed(_:))
        aiRefreshModelsButton.bezelStyle = .rounded
        aiRefreshModelsButton.setAccessibilityIdentifier("Stacio.Settings.aiRefreshModels")
        aiRefreshModelsButton.translatesAutoresizingMaskIntoConstraints = false

        aiAddCustomModelButton.target = self
        aiAddCustomModelButton.action = #selector(aiAddCustomModelPressed(_:))
        aiAddCustomModelButton.bezelStyle = .rounded
        aiAddCustomModelButton.setAccessibilityIdentifier("Stacio.Settings.aiAddCustomModel")
        aiAddCustomModelButton.translatesAutoresizingMaskIntoConstraints = false

        aiReasoningEffortControl.target = self
        aiReasoningEffortControl.action = #selector(aiReasoningEffortChanged(_:))
        aiReasoningEffortControl.setAccessibilityIdentifier("Stacio.Settings.aiReasoningEffort")
        StacioDesignSystem.styleSegmentedControl(aiReasoningEffortControl)

        aiCompatibilityProtocolControl.target = self
        aiCompatibilityProtocolControl.action = #selector(aiCompatibilityProtocolChanged(_:))
        aiCompatibilityProtocolControl.setAccessibilityIdentifier("Stacio.Settings.aiCompatibilityProtocol")
        StacioDesignSystem.styleSegmentedControl(aiCompatibilityProtocolControl)

        aiModelCatalogStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        aiModelCatalogStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aiModelCatalogStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiModelCatalogStatus")
        aiModelCatalogStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        aiAPIKeyField.placeholderString = "sk-..."
        aiAPIKeyField.target = self
        aiAPIKeyField.action = #selector(aiAPIKeyChanged(_:))
        aiAPIKeyField.delegate = self
        aiAPIKeyField.setAccessibilityIdentifier("Stacio.Settings.aiAPIKey")
        styleSettingsTextField(aiAPIKeyField)

        aiMaxRetryCountField.placeholderString = "0-5"
        aiMaxRetryCountField.target = self
        aiMaxRetryCountField.action = #selector(aiMaxRetryCountChanged(_:))
        aiMaxRetryCountField.delegate = self
        aiMaxRetryCountField.setAccessibilityIdentifier("Stacio.Settings.aiMaxRetryCount")
        styleSettingsTextField(aiMaxRetryCountField)

        aiRequestTimeoutSecondsField.placeholderString = "5-120"
        aiRequestTimeoutSecondsField.target = self
        aiRequestTimeoutSecondsField.action = #selector(aiRequestTimeoutSecondsChanged(_:))
        aiRequestTimeoutSecondsField.delegate = self
        aiRequestTimeoutSecondsField.setAccessibilityIdentifier("Stacio.Settings.aiRequestTimeoutSeconds")
        styleSettingsTextField(aiRequestTimeoutSecondsField)

        aiUserAgentField.placeholderString = "Stacio"
        aiUserAgentField.target = self
        aiUserAgentField.action = #selector(aiUserAgentChanged(_:))
        aiUserAgentField.delegate = self
        aiUserAgentField.setAccessibilityIdentifier("Stacio.Settings.aiUserAgent")
        styleSettingsTextField(aiUserAgentField)

        aiIncludeRecentTerminalTranscriptButton.target = self
        aiIncludeRecentTerminalTranscriptButton.action = #selector(aiIncludeRecentTerminalTranscriptChanged(_:))
        aiIncludeRecentTerminalTranscriptButton.setAccessibilityIdentifier("Stacio.Settings.aiIncludeRecentTerminalTranscript")
        aiIncludeRecentTerminalTranscriptButton.setAccessibilityLabel(L10n.Settings.aiIncludeRecentTerminalTranscript)
        aiIncludeRecentTerminalTranscriptButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        aiIncludeRecentTerminalTranscriptButton.translatesAutoresizingMaskIntoConstraints = false

        configureAssistantSettingsControls()

        aiContextCharacterLimitField.placeholderString = "0-24000"
        aiContextCharacterLimitField.alignment = .right
        aiContextCharacterLimitField.target = self
        aiContextCharacterLimitField.action = #selector(aiContextCharacterLimitChanged(_:))
        aiContextCharacterLimitField.delegate = self
        aiContextCharacterLimitField.setAccessibilityIdentifier("Stacio.Settings.aiContextCharacterLimit")
        styleSettingsTextField(aiContextCharacterLimitField)

        aiTestConnectionButton.target = self
        aiTestConnectionButton.action = #selector(aiTestConnectionPressed(_:))
        aiTestConnectionButton.bezelStyle = .rounded
        aiTestConnectionButton.setAccessibilityIdentifier("Stacio.Settings.aiTestConnection")
        aiTestConnectionButton.setAccessibilityLabel(L10n.Settings.aiTestConnection)
        aiTestConnectionButton.translatesAutoresizingMaskIntoConstraints = false

        aiConnectionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        aiConnectionStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aiConnectionStatusLabel.lineBreakMode = .byWordWrapping
        aiConnectionStatusLabel.maximumNumberOfLines = 2
        aiConnectionStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiConnectionStatus")
        aiConnectionStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        confirmationControl.target = self
        confirmationControl.action = #selector(confirmationPolicyChanged(_:))
        confirmationControl.setAccessibilityIdentifier("Stacio.Settings.agentConfirmationPolicy")
        StacioDesignSystem.styleSegmentedControl(confirmationControl)

        configureCommandPatternField(
            agentCommandAllowPatternsField,
            identifier: "Stacio.Settings.agentCommandAllowPatterns",
            action: #selector(agentCommandAllowPatternsChanged(_:))
        )
        configureCommandPatternField(
            agentCommandDenyPatternsField,
            identifier: "Stacio.Settings.agentCommandDenyPatterns",
            action: #selector(agentCommandDenyPatternsChanged(_:))
        )

        aiAutoRunProposedCommandsButton.target = self
        aiAutoRunProposedCommandsButton.action = #selector(aiAutoRunProposedCommandsChanged(_:))
        aiAutoRunProposedCommandsButton.setAccessibilityIdentifier("Stacio.Settings.aiAutoRunProposedCommands")
        aiAutoRunProposedCommandsButton.translatesAutoresizingMaskIntoConstraints = false

        aiClearConversationHistoryButton.target = self
        aiClearConversationHistoryButton.action = #selector(clearAIConversationHistoryPressed(_:))
        aiClearConversationHistoryButton.bezelStyle = .rounded
        aiClearConversationHistoryButton.setAccessibilityIdentifier("Stacio.Settings.clearAIConversationHistory")
        aiClearConversationHistoryButton.translatesAutoresizingMaskIntoConstraints = false
        aiClearConversationHistoryButton.isEnabled = conversationHistoryStore != nil

        aiConversationHistoryStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        aiConversationHistoryStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aiConversationHistoryStatusLabel.lineBreakMode = .byWordWrapping
        aiConversationHistoryStatusLabel.maximumNumberOfLines = 2
        aiConversationHistoryStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiConversationHistoryStatus")
        aiConversationHistoryStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        aiConversationHistoryStatusLabel.stringValue = conversationHistoryStore == nil
            ? L10n.Settings.aiConversationHistoryUnavailable
            : ""

        NSLayoutConstraint.activate([
            aiProviderPopup.widthAnchor.constraint(equalToConstant: AppSettingsLayout.popupWidth),
            aiProviderPopup.heightAnchor.constraint(equalToConstant: 34),
            aiBaseURLField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.fieldWidth),
            aiBaseURLField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiModelField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.fieldWidth),
            aiModelField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiModelCatalogPopup.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactPopupWidth),
            aiModelCatalogPopup.heightAnchor.constraint(equalToConstant: 34),
            aiCustomModelListScrollView.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth),
            aiCustomModelListScrollView.heightAnchor.constraint(equalToConstant: 148),
            aiRefreshModelsButton.heightAnchor.constraint(equalToConstant: 30),
            aiAddCustomModelButton.heightAnchor.constraint(equalToConstant: 30),
            aiReasoningEffortControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            aiReasoningEffortControl.heightAnchor.constraint(equalToConstant: 32),
            aiCompatibilityProtocolControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            aiCompatibilityProtocolControl.heightAnchor.constraint(equalToConstant: 32),
            aiAPIKeyField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.fieldWidth),
            aiAPIKeyField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiMaxRetryCountField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            aiMaxRetryCountField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiRequestTimeoutSecondsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            aiRequestTimeoutSecondsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiUserAgentField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.fieldWidth),
            aiUserAgentField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiIncludeRecentTerminalTranscriptButton.heightAnchor.constraint(equalToConstant: 28),
            aiContextCharacterLimitField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            aiContextCharacterLimitField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiTestConnectionButton.heightAnchor.constraint(equalToConstant: 32),
            aiConnectionStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.fieldWidth),
            confirmationControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            confirmationControl.heightAnchor.constraint(equalToConstant: 32),
            agentCommandAllowPatternsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            agentCommandAllowPatternsField.heightAnchor.constraint(equalToConstant: 56),
            agentCommandDenyPatternsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            agentCommandDenyPatternsField.heightAnchor.constraint(equalToConstant: 56),
            aiAutoRunProposedCommandsButton.heightAnchor.constraint(equalToConstant: 28),
            aiSendKeyModeControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            aiSendKeyModeControl.heightAnchor.constraint(equalToConstant: 32),
            aiTerminalOutputModeControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.mediumSegmentedWidth),
            aiTerminalOutputModeControl.heightAnchor.constraint(equalToConstant: 32),
            aiDefaultTerminalModeControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            aiDefaultTerminalModeControl.heightAnchor.constraint(equalToConstant: 32),
            aiTerminalRecordingScopeControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            aiTerminalRecordingScopeControl.heightAnchor.constraint(equalToConstant: 32),
            aiMaxToolStepsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            aiMaxToolStepsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiMaxModelInvocationsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            aiMaxModelInvocationsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiMaxEffectiveMinutesField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            aiMaxEffectiveMinutesField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiHistoryRetentionDaysField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            aiHistoryRetentionDaysField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            aiClearConversationHistoryButton.heightAnchor.constraint(equalToConstant: 32),
            aiConversationHistoryStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.fieldWidth)
        ])
    }

    private func configureAssistantSettingsControls() {
        configureAssistantToggle(
            aiRestoreLastConversationButton,
            identifier: "Stacio.Settings.aiRestoreLastConversation",
            action: #selector(aiRestoreLastConversationChanged(_:))
        )
        configureAssistantToggle(
            aiAutoCompressContextButton,
            identifier: "Stacio.Settings.aiAutoCompressContext",
            action: #selector(aiAutoCompressContextChanged(_:))
        )
        configureAssistantSegmentedControl(
            aiSendKeyModeControl,
            identifier: "Stacio.Settings.aiSendKeyMode",
            action: #selector(aiSendKeyModeChanged(_:))
        )
        configureAssistantSegmentedControl(
            aiTerminalOutputModeControl,
            identifier: "Stacio.Settings.aiTerminalOutputMode",
            action: #selector(aiTerminalOutputModeChanged(_:))
        )
        configureAssistantSegmentedControl(
            aiDefaultTerminalModeControl,
            identifier: "Stacio.Settings.aiDefaultTerminalMode",
            action: #selector(aiDefaultTerminalModeChanged(_:))
        )
        configureAssistantSegmentedControl(
            aiTerminalRecordingScopeControl,
            identifier: "Stacio.Settings.aiTerminalRecordingScope",
            action: #selector(aiTerminalRecordingScopeChanged(_:))
        )
        configureAssistantNumberField(
            aiMaxToolStepsField,
            placeholder: "5-200",
            identifier: "Stacio.Settings.aiMaxToolSteps",
            action: #selector(aiMaxToolStepsChanged(_:))
        )
        configureAssistantNumberField(
            aiMaxModelInvocationsField,
            placeholder: "5-200",
            identifier: "Stacio.Settings.aiMaxModelInvocations",
            action: #selector(aiMaxModelInvocationsChanged(_:))
        )
        configureAssistantNumberField(
            aiMaxEffectiveMinutesField,
            placeholder: "5-120",
            identifier: "Stacio.Settings.aiMaxEffectiveMinutes",
            action: #selector(aiMaxEffectiveMinutesChanged(_:))
        )
        configureAssistantNumberField(
            aiHistoryRetentionDaysField,
            placeholder: "1-3650",
            identifier: "Stacio.Settings.aiHistoryRetentionDays",
            action: #selector(aiHistoryRetentionDaysChanged(_:))
        )
        aiEnabledToolLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        aiEnabledToolLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        aiEnabledToolLabel.setAccessibilityIdentifier("Stacio.Settings.aiEnabledTool")
        aiEnabledToolLabel.translatesAutoresizingMaskIntoConstraints = false
        [aiSessionSettingsStatusLabel, aiContextSettingsStatusLabel, aiExecutionSettingsStatusLabel].forEach {
            $0.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            $0.textColor = StacioDesignSystem.theme.secondaryTextColor
            $0.maximumNumberOfLines = 2
            $0.lineBreakMode = .byWordWrapping
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        aiSessionSettingsStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiSessionSettingsStatus")
        aiContextSettingsStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiContextSettingsStatus")
        aiExecutionSettingsStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiExecutionSettingsStatus")
        aiPrivacyStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aiPrivacyStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        aiPrivacyStatusLabel.maximumNumberOfLines = 0
        aiPrivacyStatusLabel.lineBreakMode = .byWordWrapping
        aiPrivacyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        aiPrivacyStatusLabel.setAccessibilityIdentifier("Stacio.Settings.aiPrivacyStatus")
    }

    private func configureAssistantToggle(_ button: NSButton, identifier: String, action: Selector) {
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(button.title)
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureAssistantSegmentedControl(
        _ control: NSSegmentedControl,
        identifier: String,
        action: Selector
    ) {
        control.target = self
        control.action = action
        control.setAccessibilityIdentifier(identifier)
        control.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleSegmentedControl(control)
    }

    private func configureAssistantNumberField(
        _ field: NSTextField,
        placeholder: String,
        identifier: String,
        action: Selector
    ) {
        field.placeholderString = placeholder
        field.alignment = .right
        field.target = self
        field.action = action
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        styleSettingsTextField(field)
    }

    private func setAssistantSettingsControlsEnabled(_ enabled: Bool) {
        [
            aiRestoreLastConversationButton,
            aiSendKeyModeControl,
            aiTerminalOutputModeControl,
            aiAutoCompressContextButton,
            aiDefaultTerminalModeControl,
            aiTerminalRecordingScopeControl,
            aiMaxToolStepsField,
            aiMaxModelInvocationsField,
            aiMaxEffectiveMinutesField,
            aiHistoryRetentionDaysField
        ].forEach { $0.isEnabled = enabled }
    }

    private func configureAICustomModelList() {
        guard aiCustomModelListScrollView.documentView == nil else {
            return
        }
        aiCustomModelListScrollView.translatesAutoresizingMaskIntoConstraints = false
        aiCustomModelListScrollView.drawsBackground = false
        aiCustomModelListScrollView.borderType = .bezelBorder
        aiCustomModelListScrollView.hasVerticalScroller = true
        aiCustomModelListScrollView.autohidesScrollers = true
        aiCustomModelListScrollView.setAccessibilityIdentifier("Stacio.Settings.aiCustomModelList")

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.setAccessibilityIdentifier("Stacio.Settings.aiCustomModelListDocument")

        aiCustomModelListStack.orientation = .vertical
        aiCustomModelListStack.alignment = .leading
        aiCustomModelListStack.spacing = 6
        aiCustomModelListStack.translatesAutoresizingMaskIntoConstraints = false
        aiCustomModelListStack.setAccessibilityIdentifier("Stacio.Settings.aiCustomModelListContent")

        documentView.addSubview(aiCustomModelListStack)
        aiCustomModelListScrollView.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: aiCustomModelListScrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: aiCustomModelListScrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: aiCustomModelListScrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: aiCustomModelListScrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: aiCustomModelListScrollView.contentView.heightAnchor),

            aiCustomModelListStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 8),
            aiCustomModelListStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            aiCustomModelListStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 8),
            aiCustomModelListStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8)
        ])
    }

    private func configureFilesControls() {
        let snapshot = settingsStore.snapshot()
        filesDirectoryFollowDefaultButton.state = snapshot.filesDirectoryFollowDefault ? .on : .off
        filesShowHiddenFilesByDefaultButton.state = snapshot.filesShowHiddenFilesByDefault ? .on : .off
        filesRemoteEditAutoDetectChangesButton.state = snapshot.filesRemoteEditAutoDetectChanges ? .on : .off
        filesTransferQueueVisibleByDefaultButton.state = snapshot.filesTransferQueueVisibleByDefault ? .on : .off
        refreshFilesCacheSummary()

        guard filesControlsConfigured == false else {
            filesTransferConflictPolicyPopup.selectItem(withTitle: title(for: snapshot.filesTransferConflictPolicy))
            refreshFilesSummary()
            return
        }
        filesControlsConfigured = true
        filesTransferConflictPolicyPopup.removeAllItems()
        filesTransferConflictPolicyPopup.addItems(withTitles: FilesTransferConflictPolicyPreference.allCases.map(\.displayName))
        filesTransferConflictPolicyPopup.selectItem(withTitle: title(for: snapshot.filesTransferConflictPolicy))
        filesTransferConflictPolicyPopup.target = self
        filesTransferConflictPolicyPopup.action = #selector(filesTransferConflictPolicyChanged(_:))
        filesTransferConflictPolicyPopup.setAccessibilityIdentifier("Stacio.Settings.filesTransferConflictPolicy")
        filesTransferConflictPolicyPopup.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.stylePopupButton(filesTransferConflictPolicyPopup)
        filesDirectoryFollowDefaultButton.target = self
        filesDirectoryFollowDefaultButton.action = #selector(filesDirectoryFollowDefaultChanged(_:))
        filesDirectoryFollowDefaultButton.setAccessibilityIdentifier("Stacio.Settings.filesDirectoryFollowDefault")
        filesDirectoryFollowDefaultButton.setAccessibilityLabel(L10n.Settings.filesDirectoryFollowDefault)
        filesDirectoryFollowDefaultButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        filesDirectoryFollowDefaultButton.translatesAutoresizingMaskIntoConstraints = false
        filesShowHiddenFilesByDefaultButton.target = self
        filesShowHiddenFilesByDefaultButton.action = #selector(filesShowHiddenFilesByDefaultChanged(_:))
        filesShowHiddenFilesByDefaultButton.setAccessibilityIdentifier("Stacio.Settings.filesShowHiddenFilesByDefault")
        filesShowHiddenFilesByDefaultButton.setAccessibilityLabel(L10n.Settings.filesShowHiddenFilesByDefault)
        filesShowHiddenFilesByDefaultButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        filesShowHiddenFilesByDefaultButton.translatesAutoresizingMaskIntoConstraints = false
        filesRemoteEditAutoDetectChangesButton.target = self
        filesRemoteEditAutoDetectChangesButton.action = #selector(filesRemoteEditAutoDetectChangesChanged(_:))
        filesRemoteEditAutoDetectChangesButton.setAccessibilityIdentifier("Stacio.Settings.filesRemoteEditAutoDetectChanges")
        filesRemoteEditAutoDetectChangesButton.setAccessibilityLabel(L10n.Settings.filesRemoteEditAutoDetectChanges)
        filesRemoteEditAutoDetectChangesButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        filesRemoteEditAutoDetectChangesButton.translatesAutoresizingMaskIntoConstraints = false
        filesTransferQueueVisibleByDefaultButton.target = self
        filesTransferQueueVisibleByDefaultButton.action = #selector(filesTransferQueueVisibleByDefaultChanged(_:))
        filesTransferQueueVisibleByDefaultButton.setAccessibilityIdentifier("Stacio.Settings.filesTransferQueueVisibleByDefault")
        filesTransferQueueVisibleByDefaultButton.setAccessibilityLabel(L10n.Settings.filesTransferQueueVisibleByDefault)
        filesTransferQueueVisibleByDefaultButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        filesTransferQueueVisibleByDefaultButton.translatesAutoresizingMaskIntoConstraints = false
        filesCacheSizeLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        filesCacheSizeLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        filesCacheSizeLabel.setAccessibilityIdentifier("Stacio.Settings.filesCacheSize")
        filesCacheSizeLabel.translatesAutoresizingMaskIntoConstraints = false
        filesCacheHelpLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filesCacheHelpLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        filesCacheHelpLabel.lineBreakMode = .byWordWrapping
        filesCacheHelpLabel.maximumNumberOfLines = 0
        filesCacheHelpLabel.setAccessibilityIdentifier("Stacio.Settings.filesCacheHelp")
        filesCacheHelpLabel.translatesAutoresizingMaskIntoConstraints = false
        filesClearCacheButton.target = self
        filesClearCacheButton.action = #selector(clearFilesCachePressed(_:))
        filesClearCacheButton.setAccessibilityIdentifier("Stacio.Settings.clearCache")
        filesClearCacheButton.bezelStyle = .rounded
        filesClearCacheButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            filesDirectoryFollowDefaultButton.heightAnchor.constraint(equalToConstant: 28),
            filesShowHiddenFilesByDefaultButton.heightAnchor.constraint(equalToConstant: 28),
            filesRemoteEditAutoDetectChangesButton.heightAnchor.constraint(equalToConstant: 28),
            filesTransferConflictPolicyPopup.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactPopupWidth),
            filesTransferConflictPolicyPopup.heightAnchor.constraint(equalToConstant: 34),
            filesTransferQueueVisibleByDefaultButton.heightAnchor.constraint(equalToConstant: 28),
            filesCacheSizeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.controlColumnWidth),
            filesCacheHelpLabel.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.controlColumnWidth),
            filesClearCacheButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112)
        ])
        refreshFilesSummary()
    }

    private func configureMetricsControls() {
        let snapshot = settingsStore.snapshot()
        deviceMetricsRefreshIntervalSecondsField.stringValue = "\(snapshot.deviceMetricsRefreshIntervalSeconds)"
        deviceMetricsDisplayLocationControl.selectedSegment = snapshot.deviceMetricsDisplayLocation == .terminalBottom ? 1 : 0
        deviceMetricsKeepLastSnapshotOnFailureButton.state = snapshot.deviceMetricsKeepLastSnapshotOnFailure ? .on : .off
        deviceMetricsShowNetworkSectionButton.state = snapshot.deviceMetricsShowNetworkSection ? .on : .off
        deviceMetricsShowDiskSectionButton.state = snapshot.deviceMetricsShowDiskSection ? .on : .off
        deviceMetricsDiskMountLimitField.stringValue = "\(snapshot.deviceMetricsDiskMountLimit)"
        deviceMetricsHideVirtualNetworkInterfacesButton.state = snapshot.deviceMetricsHideVirtualNetworkInterfaces ? .on : .off
        deviceMetricsHistorySampleCountField.stringValue = "\(snapshot.deviceMetricsHistorySampleCount)"
        deviceMetricsAlertEnabledButton.state = snapshot.deviceMetricsAlertEnabled ? .on : .off
        deviceMetricsCPUAlertThresholdPercentField.stringValue = "\(snapshot.deviceMetricsCPUAlertThresholdPercent)"
        deviceMetricsMemoryAlertThresholdPercentField.stringValue = "\(snapshot.deviceMetricsMemoryAlertThresholdPercent)"
        deviceMetricsDiskAlertThresholdPercentField.stringValue = "\(snapshot.deviceMetricsDiskAlertThresholdPercent)"
        deviceMetricsAlertConsecutiveRefreshCountField.stringValue = "\(snapshot.deviceMetricsAlertConsecutiveRefreshCount)"
        refreshMetricsSummary()

        guard metricsControlsConfigured == false else {
            return
        }
        metricsControlsConfigured = true
        configureMetricsNumberField(
            deviceMetricsRefreshIntervalSecondsField,
            placeholder: "1-30",
            identifier: "Stacio.Settings.deviceMetricsRefreshIntervalSeconds",
            action: #selector(deviceMetricsRefreshIntervalSecondsChanged(_:))
        )
        deviceMetricsDisplayLocationControl.target = self
        deviceMetricsDisplayLocationControl.action = #selector(deviceMetricsDisplayLocationChanged(_:))
        deviceMetricsDisplayLocationControl.setAccessibilityIdentifier("Stacio.Settings.deviceMetricsDisplayLocation")
        deviceMetricsDisplayLocationControl.setAccessibilityLabel(L10n.Settings.deviceMetricsDisplayLocation)
        StacioDesignSystem.styleSegmentedControl(deviceMetricsDisplayLocationControl)
        // NSSegmentedControl does not always report an intrinsic width before
        // its first layout pass.  Without an explicit size the form spacer
        // can consume the whole row and collapse this setting to zero width.
        NSLayoutConstraint.activate([
            deviceMetricsDisplayLocationControl.widthAnchor.constraint(
                equalToConstant: AppSettingsLayout.mediumSegmentedWidth
            ),
            deviceMetricsDisplayLocationControl.heightAnchor.constraint(equalToConstant: 32)
        ])
        configureMetricsNumberField(
            deviceMetricsDiskMountLimitField,
            placeholder: "1-20",
            identifier: "Stacio.Settings.deviceMetricsDiskMountLimit",
            action: #selector(deviceMetricsDiskMountLimitChanged(_:))
        )
        configureMetricsNumberField(
            deviceMetricsHistorySampleCountField,
            placeholder: "3-240",
            identifier: "Stacio.Settings.deviceMetricsHistorySampleCount",
            action: #selector(deviceMetricsHistorySampleCountChanged(_:))
        )
        configureMetricsNumberField(
            deviceMetricsCPUAlertThresholdPercentField,
            placeholder: "0-100",
            identifier: "Stacio.Settings.deviceMetricsCPUAlertThresholdPercent",
            action: #selector(deviceMetricsCPUAlertThresholdPercentChanged(_:))
        )
        configureMetricsNumberField(
            deviceMetricsMemoryAlertThresholdPercentField,
            placeholder: "0-100",
            identifier: "Stacio.Settings.deviceMetricsMemoryAlertThresholdPercent",
            action: #selector(deviceMetricsMemoryAlertThresholdPercentChanged(_:))
        )
        configureMetricsNumberField(
            deviceMetricsDiskAlertThresholdPercentField,
            placeholder: "0-100",
            identifier: "Stacio.Settings.deviceMetricsDiskAlertThresholdPercent",
            action: #selector(deviceMetricsDiskAlertThresholdPercentChanged(_:))
        )
        configureMetricsNumberField(
            deviceMetricsAlertConsecutiveRefreshCountField,
            placeholder: "1-10",
            identifier: "Stacio.Settings.deviceMetricsAlertConsecutiveRefreshCount",
            action: #selector(deviceMetricsAlertConsecutiveRefreshCountChanged(_:))
        )
        configureMetricsToggleButton(
            deviceMetricsKeepLastSnapshotOnFailureButton,
            identifier: "Stacio.Settings.deviceMetricsKeepLastSnapshotOnFailure",
            action: #selector(deviceMetricsKeepLastSnapshotOnFailureChanged(_:))
        )
        configureMetricsToggleButton(
            deviceMetricsShowNetworkSectionButton,
            identifier: "Stacio.Settings.deviceMetricsShowNetworkSection",
            action: #selector(deviceMetricsShowNetworkSectionChanged(_:))
        )
        configureMetricsToggleButton(
            deviceMetricsShowDiskSectionButton,
            identifier: "Stacio.Settings.deviceMetricsShowDiskSection",
            action: #selector(deviceMetricsShowDiskSectionChanged(_:))
        )
        configureMetricsToggleButton(
            deviceMetricsHideVirtualNetworkInterfacesButton,
            identifier: "Stacio.Settings.deviceMetricsHideVirtualNetworkInterfaces",
            action: #selector(deviceMetricsHideVirtualNetworkInterfacesChanged(_:))
        )
        configureMetricsToggleButton(
            deviceMetricsAlertEnabledButton,
            identifier: "Stacio.Settings.deviceMetricsAlertEnabled",
            action: #selector(deviceMetricsAlertEnabledChanged(_:))
        )

        NSLayoutConstraint.activate([
            deviceMetricsRefreshIntervalSecondsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            deviceMetricsRefreshIntervalSecondsField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            deviceMetricsDiskMountLimitField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            deviceMetricsDiskMountLimitField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            deviceMetricsHistorySampleCountField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            deviceMetricsHistorySampleCountField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            deviceMetricsCPUAlertThresholdPercentField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            deviceMetricsCPUAlertThresholdPercentField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            deviceMetricsMemoryAlertThresholdPercentField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            deviceMetricsMemoryAlertThresholdPercentField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            deviceMetricsDiskAlertThresholdPercentField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            deviceMetricsDiskAlertThresholdPercentField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            deviceMetricsAlertConsecutiveRefreshCountField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            deviceMetricsAlertConsecutiveRefreshCountField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            deviceMetricsKeepLastSnapshotOnFailureButton.heightAnchor.constraint(equalToConstant: 28),
            deviceMetricsShowNetworkSectionButton.heightAnchor.constraint(equalToConstant: 28),
            deviceMetricsShowDiskSectionButton.heightAnchor.constraint(equalToConstant: 28),
            deviceMetricsHideVirtualNetworkInterfacesButton.heightAnchor.constraint(equalToConstant: 28),
            deviceMetricsAlertEnabledButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func configureMetricsNumberField(
        _ field: NSTextField,
        placeholder: String,
        identifier: String,
        action: Selector
    ) {
        field.placeholderString = placeholder
        field.alignment = .right
        field.target = self
        field.action = action
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        styleSettingsTextField(field)
    }

    private func configureMetricsToggleButton(_ button: NSButton, identifier: String, action: Selector) {
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(button.title)
        button.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureSecurityControls() {
        let snapshot = settingsStore.snapshot()
        securityConfirmationControl.selectedSegment = segment(for: snapshot.agentConfirmationPolicy)
        securityAgentCommandAllowPatternsField.stringValue = snapshot.agentCommandAllowPatterns
        securityAgentCommandDenyPatternsField.stringValue = snapshot.agentCommandDenyPatterns
        diagnosticsAuditExportLimitField.stringValue = "\(snapshot.diagnosticsAuditExportLimit)"
        diagnosticsAppLogLineLimitField.stringValue = "\(snapshot.diagnosticsAppLogLineLimit)"
        diagnosticsIncludeAppLogsButton.state = snapshot.diagnosticsIncludeAppLogs ? .on : .off
        refreshSecuritySummary()

        guard securityControlsConfigured == false else {
            return
        }
        securityControlsConfigured = true
        securityConfirmationControl.target = self
        securityConfirmationControl.action = #selector(securityConfirmationPolicyChanged(_:))
        securityConfirmationControl.setAccessibilityIdentifier("Stacio.Settings.securityAgentConfirmationPolicy")
        StacioDesignSystem.styleSegmentedControl(securityConfirmationControl)
        configureCommandPatternField(
            securityAgentCommandAllowPatternsField,
            identifier: "Stacio.Settings.securityAgentCommandAllowPatterns",
            action: #selector(agentCommandAllowPatternsChanged(_:))
        )
        configureCommandPatternField(
            securityAgentCommandDenyPatternsField,
            identifier: "Stacio.Settings.securityAgentCommandDenyPatterns",
            action: #selector(agentCommandDenyPatternsChanged(_:))
        )
        configureDiagnosticsLimitField(
            diagnosticsAuditExportLimitField,
            identifier: "Stacio.Settings.diagnosticsAuditExportLimit",
            action: #selector(diagnosticsAuditExportLimitChanged(_:))
        )
        configureDiagnosticsLimitField(
            diagnosticsAppLogLineLimitField,
            identifier: "Stacio.Settings.diagnosticsAppLogLineLimit",
            action: #selector(diagnosticsAppLogLineLimitChanged(_:))
        )
        diagnosticsIncludeAppLogsButton.target = self
        diagnosticsIncludeAppLogsButton.action = #selector(diagnosticsIncludeAppLogsChanged(_:))
        diagnosticsIncludeAppLogsButton.setAccessibilityIdentifier("Stacio.Settings.diagnosticsIncludeAppLogs")
        diagnosticsIncludeAppLogsButton.setAccessibilityLabel(L10n.Settings.diagnosticsIncludeAppLogs)
        diagnosticsIncludeAppLogsButton.contentTintColor = StacioDesignSystem.theme.primaryTextColor
        diagnosticsIncludeAppLogsButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            securityConfirmationControl.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            securityConfirmationControl.heightAnchor.constraint(equalToConstant: 32),
            securityAgentCommandAllowPatternsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            securityAgentCommandAllowPatternsField.heightAnchor.constraint(equalToConstant: 56),
            securityAgentCommandDenyPatternsField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.segmentedWidth),
            securityAgentCommandDenyPatternsField.heightAnchor.constraint(equalToConstant: 56),
            diagnosticsAuditExportLimitField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            diagnosticsAuditExportLimitField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            diagnosticsAppLogLineLimitField.widthAnchor.constraint(equalToConstant: AppSettingsLayout.compactFieldWidth),
            diagnosticsAppLogLineLimitField.heightAnchor.constraint(equalToConstant: AppSettingsLayout.settingsTextFieldHeight),
            diagnosticsIncludeAppLogsButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func configureCommandPatternField(_ field: NSTextField, identifier: String, action: Selector) {
        field.placeholderString = L10n.Settings.agentCommandPatternPlaceholder
        field.target = self
        field.action = action
        field.delegate = self
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 3
        field.setAccessibilityIdentifier(identifier)
        styleSettingsTextField(field)
    }

    private func configureDiagnosticsLimitField(_ field: NSTextField, identifier: String, action: Selector) {
        field.placeholderString = "0-2000"
        field.alignment = .right
        field.target = self
        field.action = action
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        styleSettingsTextField(field)
    }

    private func makeTerminalPreview() -> NSView {
        let preview = NSView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.backgroundColor = terminalPreviewBackgroundColor().cgColor
        preview.layer?.cornerRadius = 9
        preview.layer?.cornerCurve = .continuous
        preview.layer?.borderWidth = 1
        preview.layer?.borderColor = StacioDesignSystem.theme.separatorColor.cgColor
        preview.setAccessibilityIdentifier("Stacio.Settings.terminalPreview")

        let title = NSTextField(labelWithString: previewTitleText())
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = terminalPreviewForegroundColor().withAlphaComponent(0.82)
        title.setAccessibilityIdentifier("Stacio.Settings.terminalPreview.title")

        let sample = NSTextField(labelWithString: terminalPreviewSampleText())
        sample.font = TerminalAppearanceApplier.font(for: settingsStore.snapshot())
        sample.textColor = terminalPreviewForegroundColor()
        sample.maximumNumberOfLines = 5
        sample.lineBreakMode = .byTruncatingTail
        sample.setAccessibilityIdentifier("Stacio.Settings.terminalPreview.sample")

        let palette = makePreviewPaletteStrip()
        palette.setAccessibilityIdentifier("Stacio.Settings.terminalPreview.palette")

        let stack = NSStackView(views: [title, sample, palette])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        preview.addSubview(stack)
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: AppSettingsLayout.terminalPreviewWidth),
            preview.heightAnchor.constraint(equalToConstant: AppSettingsLayout.terminalPreviewHeight),
            stack.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: preview.topAnchor, constant: 16),
            palette.widthAnchor.constraint(equalTo: stack.widthAnchor),
            palette.heightAnchor.constraint(equalToConstant: 12)
        ])
        terminalPreviewView = preview
        terminalPreviewTitleLabel = title
        terminalPreviewSampleLabel = sample
        terminalPreviewPaletteView = palette
        return preview
    }

    private func makePreviewPaletteStrip() -> NSStackView {
        makeThemePaletteStrip(theme: resolvedPreviewTheme())
    }

    private func makeAIConnectionTestRow() -> NSView {
        let row = NSStackView(views: [aiTestConnectionButton, aiConnectionStatusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func terminalFontFamilyChanged(_ sender: NSPopUpButton) {
        let selection = sender.selectedItem?.representedObject as? String
        settingsStore.update { settings in
            if let selection, selection.hasPrefix("custom:") {
                settings.terminalFontFamily = .system
                settings.terminalCustomFontName = String(selection.dropFirst("custom:".count))
            } else if let selection, selection.hasPrefix("preset:") {
                let rawValue = String(selection.dropFirst("preset:".count))
                settings.terminalFontFamily = TerminalFontFamilyPreference(rawValue: rawValue) ?? .sfMono
                settings.terminalCustomFontName = nil
            } else {
                settings.terminalFontFamily = .sfMono
                settings.terminalCustomFontName = nil
            }
        }
        refreshTerminalPreview()
    }

    @objc private func fontSizeChanged(_ sender: NSTextField) {
        let parsed = Double(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 13
        settingsStore.update { settings in
            settings.terminalFontSize = parsed
        }
        sender.stringValue = "\(Int(settingsStore.snapshot().terminalFontSize))"
        refreshTerminalPreview()
    }

    @objc private func themeChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.terminalTheme = theme(for: sender.selectedSegment)
            if settings.terminalTheme == .custom, settings.customTerminalTheme == nil {
                settings.customTerminalTheme = TerminalColorTheme.portDeskDefaultCustom
            }
        }
        refreshCustomTerminalThemeLabel()
        refreshTerminalThemeCards()
        refreshTerminalPreview()
    }

    @objc private func sessionTabIconModeChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.sessionTabIconMode = sessionTabIconMode(for: sender.selectedSegment)
        }
    }

    @objc private func sessionSidebarShowRecentSessionsChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.sessionSidebarShowRecentSessions = sender.state == .on
        }
    }

    @objc private func terminalHighlightThemeChanged(_ sender: NSPopUpButton) {
        settingsStore.update { settings in
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = builtInThemeID(forTitle: sender.titleOfSelectedItem)
        }
        themeControl.selectedSegment = segment(for: .dark)
        refreshTerminalThemeCards()
        refreshTerminalPreview()
    }

    @objc private func systemAdaptiveThemeCardPressed(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalTheme = .system
        }
        themeControl.selectedSegment = segment(for: .system)
        refreshTerminalThemeCards()
        refreshTerminalPreview()
    }

    @objc private func terminalThemeCardPressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        settingsStore.update { settings in
            settings.terminalTheme = .dark
            settings.terminalBuiltInThemeID = id
        }
        themeControl.selectedSegment = segment(for: .dark)
        terminalHighlightThemePopup.selectItem(withTitle: title(forBuiltInThemeID: id))
        refreshTerminalThemeCards()
        refreshTerminalPreview()
    }

    @objc private func terminalHighlightLevelChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.terminalHighlightLevel = highlightLevel(for: sender.selectedSegment)
        }
        refreshTerminalPreview()
    }

    @objc private func terminalRichHighlightingChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalRichHighlightingEnabled = sender.state == .on
        }
        refreshTerminalPreview()
    }

    @objc private func terminalCursorStyleChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.terminalCursorShape = cursorShape(for: sender.selectedSegment)
        }
    }

    @objc private func terminalCursorBlinkChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalCursorBlinkEnabled = sender.state == .on
        }
    }

    @objc private func terminalCloseConfirmationChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalCloseConfirmationEnabled = sender.state == .on
        }
    }

    @objc private func terminalSelectionAutoCopyChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalSelectionAutoCopyEnabled = sender.state == .on
        }
    }

    @objc private func terminalRightClickBehaviorChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.terminalRightClickBehavior = rightClickBehavior(for: sender.selectedSegment)
        }
    }

    @objc private func terminalControlScrollZoomChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalControlScrollZoomEnabled = sender.state == .on
        }
    }

    @objc private func terminalScrollbackLinesChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 10_000
        let clampedValue = AppSettings.clampedTerminalScrollbackLines(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalScrollbackLines = clampedValue
        }
    }

    @objc private func terminalKeepAliveIntervalSecondsChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 60
        let clampedValue = AppSettings.clampedTerminalKeepAliveIntervalSeconds(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalKeepAliveIntervalSeconds = clampedValue
        }
    }

    @objc private func terminalX11DisplayChanged(_ sender: NSTextField) {
        let value = AppSettings.normalizedTerminalX11Display(sender.stringValue)
        sender.stringValue = value
        settingsStore.update { settings in
            settings.terminalX11Display = value
        }
    }

    @objc private func terminalHardwareAccelerationChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalHardwareAccelerationEnabled = sender.state == .on
        }
    }

    @objc private func terminalWorkspacePaddingChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalWorkspacePaddingEnabled = sender.state == .on
        }
    }

    @objc private func terminalLineNumbersChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalLineNumbersEnabled = sender.state == .on
        }
    }

    @objc private func terminalTimestampsChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalTimestampsEnabled = sender.state == .on
        }
    }

    @objc private func terminalTimestampMillisecondsChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalTimestampMillisecondsEnabled = sender.state == .on
        }
    }

    @objc private func terminalMultiLinePasteConfirmationChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalMultiLinePasteConfirmationEnabled = sender.state == .on
        }
    }

    @objc private func terminalPasteImageAsPathChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalPasteImageAsPathEnabled = sender.state == .on
        }
    }

    @objc private func terminalAltAsMetaChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalAltAsMetaEnabled = sender.state == .on
        }
    }

    @objc private func terminalMacIMECompatibilityChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalMacIMECompatibilityEnabled = sender.state == .on
        }
    }

    @objc private func terminalCommandSuggestionChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalCommandSuggestionEnabled = sender.state == .on
        }
    }

    @objc private func manageTerminalFavoriteCommandsPressed(_ sender: NSButton) {
        let controller = TerminalFavoriteCommandManagerViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "常用命令"
        window.setContentSize(NSSize(width: 760, height: 480))
        window.styleMask.insert([.titled, .closable, .resizable])
        let windowController = NSWindowController(window: window)
        favoriteCommandsWindowController = windowController
        windowController.showWindow(self)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func terminalCommandSuggestionHistoryMinLengthChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 2
        let clampedValue = AppSettings.clampedTerminalCommandSuggestionHistoryMinLength(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalCommandSuggestionHistoryMinLength = clampedValue
            settings.terminalCommandSuggestionHistoryMaxLength = max(
                settings.terminalCommandSuggestionHistoryMaxLength,
                clampedValue
            )
        }
        terminalCommandSuggestionHistoryMaxLengthField.stringValue = "\(settingsStore.snapshot().terminalCommandSuggestionHistoryMaxLength)"
    }

    @objc private func terminalCommandSuggestionHistoryMaxLengthChanged(_ sender: NSTextField) {
        let snapshot = settingsStore.snapshot()
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? snapshot.terminalCommandSuggestionHistoryMaxLength
        let clampedValue = max(
            snapshot.terminalCommandSuggestionHistoryMinLength,
            AppSettings.clampedTerminalCommandSuggestionHistoryMaxLength(value)
        )
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalCommandSuggestionHistoryMaxLength = clampedValue
        }
    }

    @objc private func terminalCommandSuggestionWordSeparatorsChanged(_ sender: NSTextField) {
        let value = AppSettings.normalizedTerminalCommandSuggestionWordSeparators(sender.stringValue)
        sender.stringValue = value
        settingsStore.update { settings in
            settings.terminalCommandSuggestionWordSeparators = value
        }
    }

    @objc private func terminalDuplicateSessionCommandDelayMillisecondsChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1_000
        let clampedValue = AppSettings.clampedTerminalDuplicateSessionCommandDelayMilliseconds(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalDuplicateSessionCommandDelayMilliseconds = clampedValue
        }
    }

    @objc private func terminalCommandCompletionNotificationChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalCommandCompletionNotificationEnabled = sender.state == .on
        }
    }

    @objc private func terminalCommandCompletionNotificationThresholdSecondsChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
        let clampedValue = AppSettings.clampedTerminalCommandCompletionNotificationThresholdSeconds(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalCommandCompletionNotificationThresholdSeconds = clampedValue
        }
    }

    @objc private func terminalAutomaticReconnectChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.terminalAutomaticReconnectEnabled = sender.state == .on
        }
    }

    @objc private func terminalAutomaticReconnectIntervalChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
        let clampedValue = AppSettings.clampedTerminalAutomaticReconnectIntervalSeconds(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalAutomaticReconnectIntervalSeconds = clampedValue
        }
    }

    @objc private func terminalAutomaticReconnectAttemptsChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 3
        let clampedValue = AppSettings.clampedTerminalAutomaticReconnectAttempts(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.terminalAutomaticReconnectAttempts = clampedValue
        }
    }

    @objc private func importTerminalThemePressed(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .json,
            .propertyList,
            UTType(filenameExtension: "conf") ?? .plainText,
            UTType(filenameExtension: "theme") ?? .plainText,
            UTType(filenameExtension: "toml") ?? .plainText,
            UTType(filenameExtension: "staciotheme") ?? .json,
            UTType(filenameExtension: "itermcolors") ?? .propertyList
        ]
        panel.message = L10n.Settings.terminalThemeImportHint
        let response = panel.runModal()
        guard response == .OK,
              let url = panel.url
        else {
            return
        }
        do {
            let theme = try TerminalThemeImporter.importTheme(
                data: Data(contentsOf: url),
                suggestedName: url.deletingPathExtension().lastPathComponent,
                fileExtension: url.pathExtension
            )
            settingsStore.update { settings in
                settings.terminalTheme = .custom
                settings.customTerminalTheme = theme
            }
            themeControl.selectedSegment = segment(for: .custom)
            refreshCustomTerminalThemeLabel()
            refreshTerminalThemeCards()
            refreshTerminalPreview()
        } catch {
            customTerminalThemeLabel.stringValue = "\(L10n.Settings.aiConnectionFailedPrefix)\(RuntimeDiagnosticFormatter.userMessage(for: error))"
            customTerminalThemeLabel.textColor = StacioDesignSystem.theme.dangerColor
        }
    }

    @objc private func aiProviderChanged(_ sender: NSPopUpButton) {
        let profile = profile(forTitle: sender.titleOfSelectedItem ?? L10n.Settings.portDeskRules)
        settingsStore.update { settings in
            settings.aiProvider = profile.rawValue
        }
        let snapshot = settingsStore.snapshot()
        aiBaseURLField.stringValue = snapshot.aiBaseURL
        aiModelField.stringValue = snapshot.aiModel
        refreshAIProviderFieldAvailability()
        refreshAIModelCatalogControls(status: providerSelectionStatus(for: profile))
        refreshAISummary()
    }

    @objc private func aiBaseURLChanged(_ sender: NSTextField) {
        settingsStore.update { settings in
            settings.aiBaseURL = sender.stringValue
        }
    }

    @objc private func aiModelChanged(_ sender: NSTextField) {
        settingsStore.update { settings in
            settings.aiModel = sender.stringValue
        }
        refreshAIModelCatalogControls()
    }

    @objc private func aiModelCatalogChanged(_ sender: NSPopUpButton) {
        guard let model = sender.titleOfSelectedItem,
              model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return
        }
        aiModelField.stringValue = model
        settingsStore.update { settings in
            settings.aiModel = model
        }
        refreshAIModelCatalogControls()
    }

    @objc private func aiAddCustomModelPressed(_ sender: NSButton) {
        guard AIProviderProfile.isModelInterfaceProvider(settingsStore.snapshot().aiProvider) else {
            aiModelCatalogStatusLabel.stringValue = "Stacio 规则模式无需模型列表。"
            return
        }
        let model = aiModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty == false else {
            aiModelCatalogStatusLabel.stringValue = "请先填写模型名。"
            return
        }
        settingsStore.update { settings in
            settings.aiCustomModels = AppSettings.normalizedAIModelList(settings.aiCustomModels + [model])
            settings.aiModel = model
        }
        aiModelField.stringValue = model
        refreshAIModelCatalogControls()
    }

    @objc private func aiRemoveCustomModelPressed(_ sender: NSButton) {
        guard let model = sender.identifier?.rawValue,
              model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return
        }
        settingsStore.update { settings in
            let remaining = AppSettings.normalizedAIModelList(settings.aiCustomModels.filter { $0 != model })
            settings.aiCustomModels = remaining
            if settings.aiModel == model {
                settings.aiModel = remaining.first ?? ""
            }
        }
        aiModelField.stringValue = settingsStore.snapshot().aiModel
        refreshAIModelCatalogControls()
    }

    @objc private func aiRefreshModelsPressed(_ sender: NSButton) {
        commitAIConfigurationFields()
        guard AIProviderProfile.isModelInterfaceProvider(settingsStore.snapshot().aiProvider) else {
            aiModelCatalogStatusLabel.stringValue = "Stacio 规则模式无需刷新模型。"
            refreshAIModelCatalogControls(status: aiModelCatalogStatusLabel.stringValue)
            return
        }
        sender.isEnabled = false
        aiModelCatalogStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        aiModelCatalogStatusLabel.stringValue = "正在刷新模型列表..."
        let loader = UncheckedAIModelCatalogLoaderBox(aiModelCatalogLoader)
        let keyStore = UncheckedAIApiKeyStoreBox(aiAPIKeyStore)
        let settings = settingsStore.snapshot()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try loader.value.listModels(settings: settings, apiKeyStore: keyStore.value)
            }
            DispatchQueue.main.async { [weak self, weak sender] in
                guard let self else { return }
                sender?.isEnabled = true
                switch result {
                case .success(let models):
                    let normalized = AppSettings.normalizedAIModelList(models + [self.aiModelField.stringValue])
                    self.settingsStore.update { settings in
                        settings.aiCustomModels = normalized
                    }
                    self.aiModelCatalogStatusLabel.textColor = StacioDesignSystem.theme.successColor
                    self.refreshAIModelCatalogControls(status: "已刷新 \(normalized.count) 个模型。")
                case .failure(let error):
                    self.aiModelCatalogStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                    self.aiModelCatalogStatusLabel.stringValue = "\(L10n.Settings.aiConnectionFailedPrefix)\(RuntimeDiagnosticFormatter.userMessage(for: error))"
                    self.refreshAIModelCatalogControls(status: self.aiModelCatalogStatusLabel.stringValue)
                }
            }
        }
    }

    @objc private func aiReasoningEffortChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.aiReasoningEffort = reasoningEffort(for: sender.selectedSegment)
        }
    }

    @objc private func aiCompatibilityProtocolChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.aiCompatibilityProtocol = compatibilityProtocol(for: sender.selectedSegment)
        }
    }

    @objc private func aiMaxRetryCountChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        let clampedValue = AppSettings.clampedAIRetryCount(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.aiMaxRetryCount = clampedValue
        }
    }

    @objc private func aiRequestTimeoutSecondsChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 45
        let clampedValue = AppSettings.clampedAITimeoutSeconds(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.aiRequestTimeoutSeconds = clampedValue
        }
    }

    @objc private func aiUserAgentChanged(_ sender: NSTextField) {
        let value = AppSettings.normalizedAIUserAgent(sender.stringValue)
        sender.stringValue = value
        settingsStore.update { settings in
            settings.aiUserAgent = value
        }
    }

    @objc private func aiIncludeRecentTerminalTranscriptChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.aiIncludeRecentTerminalTranscript = sender.state == .on
        }
    }

    @objc private func aiContextCharacterLimitChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 12_000
        let clampedValue = AppSettings.clampedAIContextCharacterLimit(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.aiContextCharacterLimit = clampedValue
        }
    }

    @objc private func aiRestoreLastConversationChanged(_ sender: NSButton) {
        writeAssistantSetting(
            id: "assistant.general.restoreLastConversation",
            value: .bool(sender.state == .on),
            statusLabel: aiSessionSettingsStatusLabel
        )
    }

    @objc private func aiSendKeyModeChanged(_ sender: NSSegmentedControl) {
        writeAssistantSetting(
            id: "assistant.general.sendKeyMode",
            value: .string(sender.selectedSegment == 1 ? "commandReturn" : "return"),
            statusLabel: aiSessionSettingsStatusLabel
        )
    }

    @objc private func aiTerminalOutputModeChanged(_ sender: NSSegmentedControl) {
        let value: String
        switch sender.selectedSegment {
        case 1: value = "summaryOnly"
        case 2: value = "excluded"
        default: value = "boundedHeadTail"
        }
        writeAssistantSetting(
            id: "assistant.context.terminalOutputMode",
            value: .string(value),
            statusLabel: aiContextSettingsStatusLabel
        )
    }

    @objc private func aiAutoCompressContextChanged(_ sender: NSButton) {
        writeAssistantSetting(
            id: "assistant.context.autoCompression",
            value: .bool(sender.state == .on),
            statusLabel: aiContextSettingsStatusLabel
        )
    }

    @objc private func aiDefaultTerminalModeChanged(_ sender: NSSegmentedControl) {
        let value: String
        switch sender.selectedSegment {
        case 1:
            value = "backgroundVirtualTerminal"
        case 2:
            value = "ask"
        default:
            value = "realTerminal"
        }
        writeAssistantSetting(
            id: "assistant.execution.defaultTerminalMode",
            value: .string(value),
            statusLabel: aiExecutionSettingsStatusLabel
        )
    }

    @objc private func aiMaxToolStepsChanged(_ sender: NSTextField) {
        writeAssistantInteger(
            field: sender,
            id: "assistant.execution.maxToolSteps",
            range: 5...200,
            fallback: 40,
            statusLabel: aiExecutionSettingsStatusLabel
        )
    }

    @objc private func aiMaxModelInvocationsChanged(_ sender: NSTextField) {
        writeAssistantInteger(
            field: sender,
            id: "assistant.usage.maxModelInvocations",
            range: 5...200,
            fallback: 40,
            statusLabel: aiExecutionSettingsStatusLabel
        )
    }

    @objc private func aiMaxEffectiveMinutesChanged(_ sender: NSTextField) {
        writeAssistantInteger(
            field: sender,
            id: "assistant.execution.maxEffectiveMinutes",
            range: 5...120,
            fallback: 30,
            statusLabel: aiExecutionSettingsStatusLabel
        )
    }

    @objc private func aiHistoryRetentionDaysChanged(_ sender: NSTextField) {
        writeAssistantInteger(
            field: sender,
            id: "assistant.history.retention",
            range: 1...3_650,
            fallback: 30,
            statusLabel: aiConversationHistoryStatusLabel
        )
    }

    @objc private func aiTerminalRecordingScopeChanged(_ sender: NSSegmentedControl) {
        let value: String
        switch sender.selectedSegment {
        case 0: value = "none"
        case 2: value = "fullWhenAudited"
        default: value = "bounded"
        }
        writeAssistantSetting(
            id: "assistant.privacy.terminalRecordingScope",
            value: .string(value),
            statusLabel: aiConversationHistoryStatusLabel
        )
    }

    private func writeAssistantInteger(
        field: NSTextField,
        id: String,
        range: ClosedRange<Int>,
        fallback: Int,
        statusLabel: NSTextField
    ) {
        let parsed = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
        let value = min(max(parsed, range.lowerBound), range.upperBound)
        field.stringValue = "\(value)"
        writeAssistantSetting(id: id, value: .int(value), statusLabel: statusLabel)
    }

    private func writeAssistantSetting(
        id: String,
        value: SettingValue,
        statusLabel: NSTextField
    ) {
        guard let assistantSettingsMutationCoordinator else {
            statusLabel.textColor = StacioDesignSystem.theme.dangerColor
            statusLabel.stringValue = L10n.Settings.aiAssistantSettingUnavailable
            configureAIControls()
            return
        }
        statusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        statusLabel.stringValue = "正在保存..."
        setAssistantSettingsControlsEnabled(false)
        assistantSettingsMutationCoordinator.write(settingID: id, value: value) { [weak self, weak statusLabel] result in
            DispatchQueue.main.async {
                guard let self, let statusLabel else { return }
                self.setAssistantSettingsControlsEnabled(true)
                switch result {
                case .success:
                    statusLabel.textColor = StacioDesignSystem.theme.successColor
                    statusLabel.stringValue = L10n.Settings.aiAssistantSettingSaved
                case .failure(.historyPruningFailed):
                    statusLabel.textColor = StacioDesignSystem.theme.warningColor
                    statusLabel.stringValue = L10n.Settings.aiHistoryRetentionSavedPruningFailed
                    self.configureAIControls()
                case .failure:
                    statusLabel.textColor = StacioDesignSystem.theme.dangerColor
                    statusLabel.stringValue = L10n.Settings.aiAssistantSettingSaveFailed
                    self.configureAIControls()
                }
            }
        }
    }

    @objc private func aiAPIKeyChanged(_ sender: NSSecureTextField) {
        let legacyProviderID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let value = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if value.isEmpty {
                try aiAPIKeyStore.deleteAPIKey(for: legacyProviderID)
            } else {
                try aiAPIKeyStore.saveAPIKey(value, for: legacyProviderID)
            }
        } catch {
            sender.stringValue = (try? aiAPIKeyStore.readAPIKey(for: legacyProviderID)) ?? ""
        }
    }

    @objc private func aiTestConnectionPressed(_ sender: NSButton) {
        commitAIConfigurationFields()
        sender.isEnabled = false
        aiConnectionStatusLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        aiConnectionStatusLabel.stringValue = L10n.Settings.aiConnectionTesting

        let tester = UncheckedAIAssistantConnectionTesterBox(aiConnectionTester)
        let keyStore = UncheckedAIApiKeyStoreBox(aiAPIKeyStore)
        let settings = settingsStore.snapshot()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try tester.value.testConnection(settings: settings, apiKeyStore: keyStore.value)
            }
            DispatchQueue.main.async { [weak self, weak sender] in
                guard let self else { return }
                sender?.isEnabled = true
                switch result {
                case .success(let connectionResult):
                    self.aiConnectionStatusLabel.textColor = StacioDesignSystem.theme.successColor
                    self.aiConnectionStatusLabel.stringValue = connectionResult.message
                case .failure(let error):
                    self.aiConnectionStatusLabel.textColor = StacioDesignSystem.theme.dangerColor
                    self.aiConnectionStatusLabel.stringValue = "\(L10n.Settings.aiConnectionFailedPrefix)\(RuntimeDiagnosticFormatter.userMessage(for: error))"
                }
            }
        }
    }

    private func commitAIConfigurationFields() {
        commitAIProviderSelection()
        aiBaseURLChanged(aiBaseURLField)
        aiModelChanged(aiModelField)
        aiMaxRetryCountChanged(aiMaxRetryCountField)
        aiRequestTimeoutSecondsChanged(aiRequestTimeoutSecondsField)
        aiUserAgentChanged(aiUserAgentField)
        aiIncludeRecentTerminalTranscriptChanged(aiIncludeRecentTerminalTranscriptButton)
        aiContextCharacterLimitChanged(aiContextCharacterLimitField)
        aiAPIKeyChanged(aiAPIKeyField)
    }

    private func commitAIProviderSelection() {
        let profile = profile(forTitle: aiProviderPopup.titleOfSelectedItem ?? L10n.Settings.portDeskRules)
        settingsStore.update { settings in
            settings.aiProvider = profile.rawValue
        }
    }

    @objc private func confirmationPolicyChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.agentConfirmationPolicy = confirmationPolicy(for: sender.selectedSegment)
        }
        securityConfirmationControl.selectedSegment = sender.selectedSegment
        refreshAISummary()
        refreshSecuritySummary()
    }

    @objc private func aiAutoRunProposedCommandsChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.aiAutoRunProposedCommands = sender.state == .on
        }
        refreshAISummary()
    }

    @objc private func agentCommandAllowPatternsChanged(_ sender: NSTextField) {
        settingsStore.update { settings in
            settings.agentCommandAllowPatterns = sender.stringValue
        }
        syncCommandPatternFields()
        refreshAISummary()
        refreshSecuritySummary()
    }

    @objc private func agentCommandDenyPatternsChanged(_ sender: NSTextField) {
        settingsStore.update { settings in
            settings.agentCommandDenyPatterns = sender.stringValue
        }
        syncCommandPatternFields()
        refreshAISummary()
        refreshSecuritySummary()
    }

    @objc private func filesDirectoryFollowDefaultChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.filesDirectoryFollowDefault = sender.state == .on
        }
        refreshFilesSummary()
    }

    @objc private func filesShowHiddenFilesByDefaultChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.filesShowHiddenFilesByDefault = sender.state == .on
        }
        refreshFilesSummary()
    }

    @objc private func filesRemoteEditAutoDetectChangesChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.filesRemoteEditAutoDetectChanges = sender.state == .on
        }
        refreshFilesSummary()
    }

    @objc private func filesTransferConflictPolicyChanged(_ sender: NSPopUpButton) {
        settingsStore.update { settings in
            settings.filesTransferConflictPolicy = conflictPolicy(forTitle: sender.titleOfSelectedItem)
        }
        refreshFilesSummary()
    }

    @objc private func clearFilesCachePressed(_ sender: NSButton) {
        do {
            let summary = try cacheMaintenance.cacheSummary()
            guard cacheClearPresenter.confirmClearCaches(summary: summary, parentWindow: view.window) else {
                return
            }
            let result = try cacheMaintenance.clearAllCaches()
            cacheClearPresenter.presentClearCachesComplete(result: result, parentWindow: view.window)
            refreshFilesCacheSummary()
        } catch {
            cacheClearPresenter.presentClearCachesError(error, parentWindow: view.window)
        }
    }

    @objc private func clearAIConversationHistoryPressed(_ sender: NSButton) {
        guard let conversationHistoryStore else {
            aiConversationHistoryStatusLabel.stringValue = L10n.Settings.aiConversationHistoryUnavailable
            return
        }
        guard aiConversationHistoryClearConfirmation.confirmClearAIConversationHistory(
            parentWindow: view.window
        ) else {
            return
        }
        do {
            try conversationHistoryStore.clearConversationHistory()
            aiConversationHistoryStatusLabel.stringValue = L10n.Settings.aiConversationHistoryCleared
        } catch {
            aiConversationHistoryStatusLabel.stringValue = RuntimeDiagnosticFormatter.userMessage(for: error)
        }
    }

    @objc private func filesTransferQueueVisibleByDefaultChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.filesTransferQueueVisibleByDefault = sender.state == .on
        }
        refreshFilesSummary()
    }

    @objc private func deviceMetricsRefreshIntervalSecondsChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 2
        let clampedValue = AppSettings.clampedDeviceMetricsRefreshIntervalSeconds(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.deviceMetricsRefreshIntervalSeconds = clampedValue
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsDisplayLocationChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.deviceMetricsDisplayLocation = sender.selectedSegment == 1 ? .terminalBottom : .floating
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsKeepLastSnapshotOnFailureChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.deviceMetricsKeepLastSnapshotOnFailure = sender.state == .on
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsShowNetworkSectionChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.deviceMetricsShowNetworkSection = sender.state == .on
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsShowDiskSectionChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.deviceMetricsShowDiskSection = sender.state == .on
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsDiskMountLimitChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 5
        let clampedValue = AppSettings.clampedDeviceMetricsDiskMountLimit(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.deviceMetricsDiskMountLimit = clampedValue
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsHideVirtualNetworkInterfacesChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.deviceMetricsHideVirtualNetworkInterfaces = sender.state == .on
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsHistorySampleCountChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 42
        let clampedValue = AppSettings.clampedDeviceMetricsHistorySampleCount(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.deviceMetricsHistorySampleCount = clampedValue
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsAlertEnabledChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.deviceMetricsAlertEnabled = sender.state == .on
        }
        refreshMetricsSummary()
    }

    @objc private func deviceMetricsCPUAlertThresholdPercentChanged(_ sender: NSTextField) {
        updateDeviceMetricsAlertThresholdField(sender) { settings, value in
            settings.deviceMetricsCPUAlertThresholdPercent = value
        }
    }

    @objc private func deviceMetricsMemoryAlertThresholdPercentChanged(_ sender: NSTextField) {
        updateDeviceMetricsAlertThresholdField(sender) { settings, value in
            settings.deviceMetricsMemoryAlertThresholdPercent = value
        }
    }

    @objc private func deviceMetricsDiskAlertThresholdPercentChanged(_ sender: NSTextField) {
        updateDeviceMetricsAlertThresholdField(sender) { settings, value in
            settings.deviceMetricsDiskAlertThresholdPercent = value
        }
    }

    @objc private func deviceMetricsAlertConsecutiveRefreshCountChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 2
        let clampedValue = AppSettings.clampedDeviceMetricsAlertConsecutiveRefreshCount(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.deviceMetricsAlertConsecutiveRefreshCount = clampedValue
        }
        refreshMetricsSummary()
    }

    private func updateDeviceMetricsAlertThresholdField(
        _ sender: NSTextField,
        apply: (inout AppSettings, Int) -> Void
    ) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 90
        let normalizedValue = AppSettings.normalizedDeviceMetricsAlertThresholdPercent(value)
        sender.stringValue = "\(normalizedValue)"
        settingsStore.update { settings in
            apply(&settings, normalizedValue)
        }
        refreshMetricsSummary()
    }

    @objc private func securityConfirmationPolicyChanged(_ sender: NSSegmentedControl) {
        settingsStore.update { settings in
            settings.agentConfirmationPolicy = confirmationPolicy(for: sender.selectedSegment)
        }
        confirmationControl.selectedSegment = sender.selectedSegment
        refreshAISummary()
        refreshSecuritySummary()
    }

    @objc private func diagnosticsAuditExportLimitChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 20
        let clampedValue = AppSettings.clampedDiagnosticsAuditExportLimit(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.diagnosticsAuditExportLimit = clampedValue
        }
        refreshSecuritySummary()
    }

    @objc private func diagnosticsAppLogLineLimitChanged(_ sender: NSTextField) {
        let value = Int(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 200
        let clampedValue = AppSettings.clampedDiagnosticsAppLogLineLimit(value)
        sender.stringValue = "\(clampedValue)"
        settingsStore.update { settings in
            settings.diagnosticsAppLogLineLimit = clampedValue
        }
        refreshSecuritySummary()
    }

    @objc private func diagnosticsIncludeAppLogsChanged(_ sender: NSButton) {
        settingsStore.update { settings in
            settings.diagnosticsIncludeAppLogs = sender.state == .on
        }
        refreshSecuritySummary()
    }

    @objc private func credentialCenterSelectionChanged(_ sender: NSPopUpButton) {
        refreshCredentialCenterSummary()
    }

    @objc private func refreshCredentialCenterPressed(_ sender: NSButton) {
        refreshCredentialCenter()
    }

    @objc private func credentialCenterInputChanged(_ sender: NSTextField) {
        updateCredentialCenterAddButtonState()
    }

    @objc private func addCredentialCenterPasswordPressed(_ sender: NSButton) {
        addCredentialCenterCredential(kind: "password")
    }

    @objc private func addCredentialCenterPrivateKeyPassphrasePressed(_ sender: NSButton) {
        addCredentialCenterCredential(kind: "private_key_passphrase")
    }

    @objc private func addCredentialCenterTokenPressed(_ sender: NSButton) {
        addCredentialCenterCredential(kind: "token")
    }

    private func addCredentialCenterCredential(kind: String) {
        let label = credentialCenterNewLabelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = credentialCenterNewAccountField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = credentialCenterNewSecretField.stringValue
        guard account.isEmpty == false, secret.isEmpty == false else {
            credentialCenterSummaryLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
            credentialCenterSummaryLabel.stringValue = L10n.Settings.credentialCenterInputRequired
            updateCredentialCenterAddButtonState()
            return
        }
        do {
            let record = try credentialCenterStore?.saveCredential(
                kind: kind,
                label: label.isEmpty ? account : label,
                account: account,
                secret: secret
            )
            credentialCenterNewSecretField.stringValue = ""
            updateCredentialCenterAddButtonState()
            refreshCredentialCenter()
            if let record {
                credentialCenterListPopup.selectItem(withTitle: credentialCenterTitle(for: record))
                refreshCredentialCenterSummary()
                credentialCenterSummaryLabel.stringValue = "\(L10n.Settings.credentialCenterSavedPrefix)\(record.label) · \(record.keychainAccount) · \(credentialCenterRecords.count) 个凭据引用"
            }
        } catch {
            credentialCenterSummaryLabel.textColor = StacioDesignSystem.theme.dangerColor
            credentialCenterSummaryLabel.stringValue = "\(L10n.Settings.aiConnectionFailedPrefix)\(RuntimeDiagnosticFormatter.userMessage(for: error))"
        }
    }

    @objc private func deleteCredentialCenterSelectionPressed(_ sender: NSButton) {
        let index = credentialCenterListPopup.indexOfSelectedItem
        guard credentialCenterRecords.indices.contains(index) else {
            return
        }
        do {
            try credentialCenterStore?.deleteCredential(id: credentialCenterRecords[index].id)
            refreshCredentialCenter()
        } catch {
            credentialCenterSummaryLabel.textColor = StacioDesignSystem.theme.dangerColor
            credentialCenterSummaryLabel.stringValue = "\(L10n.Settings.aiConnectionFailedPrefix)\(RuntimeDiagnosticFormatter.userMessage(for: error))"
        }
    }

    @objc private func copyAgentBridgeSocketPressed(_ sender: NSButton) {
        copyToPasteboard(agentBridgeSocketLabel.stringValue)
    }

    @objc private func copyApplicationSupportPathPressed(_ sender: NSButton) {
        copyToPasteboard(applicationSupportPathLabel.stringValue)
    }

    @objc private func copyDatabasePathPressed(_ sender: NSButton) {
        copyToPasteboard(databasePathLabel.stringValue)
    }

    @objc private func copyLogPathPressed(_ sender: NSButton) {
        copyToPasteboard(logPathLabel.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else {
            return
        }
        switch field {
        case aiBaseURLField:
            aiBaseURLChanged(aiBaseURLField)
        case aiModelField:
            aiModelChanged(aiModelField)
        case aiAPIKeyField:
            aiAPIKeyChanged(aiAPIKeyField)
        case aiMaxRetryCountField:
            aiMaxRetryCountChanged(aiMaxRetryCountField)
        case aiRequestTimeoutSecondsField:
            aiRequestTimeoutSecondsChanged(aiRequestTimeoutSecondsField)
        case aiUserAgentField:
            aiUserAgentChanged(aiUserAgentField)
        case aiContextCharacterLimitField:
            aiContextCharacterLimitChanged(aiContextCharacterLimitField)
        case terminalCommandCompletionNotificationThresholdSecondsField:
            terminalCommandCompletionNotificationThresholdSecondsChanged(terminalCommandCompletionNotificationThresholdSecondsField)
        case terminalAutomaticReconnectIntervalField:
            terminalAutomaticReconnectIntervalChanged(terminalAutomaticReconnectIntervalField)
        case terminalAutomaticReconnectAttemptsField:
            terminalAutomaticReconnectAttemptsChanged(terminalAutomaticReconnectAttemptsField)
        case terminalScrollbackLinesField:
            terminalScrollbackLinesChanged(terminalScrollbackLinesField)
        case terminalKeepAliveIntervalSecondsField:
            terminalKeepAliveIntervalSecondsChanged(terminalKeepAliveIntervalSecondsField)
        case terminalX11DisplayField:
            terminalX11DisplayChanged(terminalX11DisplayField)
        case terminalCommandSuggestionHistoryMinLengthField:
            terminalCommandSuggestionHistoryMinLengthChanged(terminalCommandSuggestionHistoryMinLengthField)
        case terminalCommandSuggestionHistoryMaxLengthField:
            terminalCommandSuggestionHistoryMaxLengthChanged(terminalCommandSuggestionHistoryMaxLengthField)
        case terminalCommandSuggestionWordSeparatorsField:
            terminalCommandSuggestionWordSeparatorsChanged(terminalCommandSuggestionWordSeparatorsField)
        case terminalDuplicateSessionCommandDelayMillisecondsField:
            terminalDuplicateSessionCommandDelayMillisecondsChanged(terminalDuplicateSessionCommandDelayMillisecondsField)
        case deviceMetricsRefreshIntervalSecondsField:
            deviceMetricsRefreshIntervalSecondsChanged(deviceMetricsRefreshIntervalSecondsField)
        case deviceMetricsDiskMountLimitField:
            deviceMetricsDiskMountLimitChanged(deviceMetricsDiskMountLimitField)
        case deviceMetricsHistorySampleCountField:
            deviceMetricsHistorySampleCountChanged(deviceMetricsHistorySampleCountField)
        case diagnosticsAuditExportLimitField:
            diagnosticsAuditExportLimitChanged(diagnosticsAuditExportLimitField)
        case diagnosticsAppLogLineLimitField:
            diagnosticsAppLogLineLimitChanged(diagnosticsAppLogLineLimitField)
        case credentialCenterNewLabelField,
             credentialCenterNewAccountField,
             credentialCenterNewSecretField:
            updateCredentialCenterAddButtonState()
        default:
            break
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else {
            return
        }
        switch field {
        case credentialCenterNewLabelField,
             credentialCenterNewAccountField,
             credentialCenterNewSecretField:
            updateCredentialCenterAddButtonState()
        default:
            break
        }
    }

    private func segment(for theme: TerminalThemePreference) -> Int {
        switch theme {
        case .system:
            return 0
        case .light:
            return 1
        case .dark:
            return 2
        case .custom:
            return 3
        }
    }

    private func theme(for segment: Int) -> TerminalThemePreference {
        switch segment {
        case 1:
            return .light
        case 2:
            return .dark
        case 3:
            return .custom
        default:
            return .system
        }
    }

    private func segment(for mode: SessionTabIconModePreference) -> Int {
        switch mode {
        case .defaultIcon:
            return 0
        case .operatingSystem:
            return 1
        }
    }

    private func sessionTabIconMode(for segment: Int) -> SessionTabIconModePreference {
        segment == 1 ? .operatingSystem : .defaultIcon
    }

    private func title(
        for fontFamily: TerminalFontFamilyPreference,
        customFontName: String? = nil
    ) -> String {
        if fontFamily == .system,
           let customFontName,
           !customFontName.isEmpty {
            return customFontName
        }
        return fontFamily.displayName
    }

    private func addTerminalFontItem(title: String, representedObject: String) {
        terminalFontFamilyPopup.addItem(withTitle: title)
        terminalFontFamilyPopup.lastItem?.representedObject = representedObject
    }

    private func title(forBuiltInThemeID themeID: String) -> String {
        TerminalColorTheme.resolvedBuiltInTheme(id: themeID).name
    }

    private func builtInThemeID(forTitle title: String?) -> String {
        TerminalColorTheme.builtInThemes.first { $0.name == title }?.id
            ?? TerminalColorTheme.portDeskDark.id
            ?? "stacio-dark"
    }

    private func title(for conflictPolicy: FilesTransferConflictPolicyPreference) -> String {
        conflictPolicy.displayName
    }

    private func conflictPolicy(forTitle title: String?) -> FilesTransferConflictPolicyPreference {
        FilesTransferConflictPolicyPreference.allCases.first { $0.displayName == title } ?? .ask
    }

    private func segment(for highlightLevel: TerminalHighlightLevelPreference) -> Int {
        switch highlightLevel {
        case .off:
            return 0
        case .ansiOnly:
            return 1
        case .commandLineEnhanced:
            return 2
        }
    }

    private func highlightLevel(for segment: Int) -> TerminalHighlightLevelPreference {
        switch segment {
        case 0:
            return .off
        case 2:
            return .commandLineEnhanced
        default:
            return .ansiOnly
        }
    }

    private func segment(for cursorShape: TerminalCursorShapePreference) -> Int {
        switch cursorShape {
        case .block:
            return 0
        case .bar:
            return 1
        case .underline:
            return 2
        }
    }

    private func cursorShape(for segment: Int) -> TerminalCursorShapePreference {
        switch segment {
        case 1:
            return .bar
        case 2:
            return .underline
        default:
            return .block
        }
    }

    private func segment(for behavior: TerminalRightClickBehaviorPreference) -> Int {
        switch behavior {
        case .paste:
            return 0
        case .contextMenu:
            return 1
        case .none:
            return 2
        }
    }

    private func rightClickBehavior(for segment: Int) -> TerminalRightClickBehaviorPreference {
        switch segment {
        case 1:
            return .contextMenu
        case 2:
            return .none
        default:
            return .paste
        }
    }

    private func segment(for policy: AgentConfirmationPolicyPreference) -> Int {
        switch policy {
        case .allowAllWithoutPrompt:
            return 0
        case .allowLowRiskWithoutPrompt:
            return 1
        case .allowReadOnlyWithoutPrompt:
            return 2
        case .requireEveryCommand:
            return 3
        }
    }

    private func confirmationPolicy(for segment: Int) -> AgentConfirmationPolicyPreference {
        switch segment {
        case 0:
            return .allowAllWithoutPrompt
        case 1:
            return .allowLowRiskWithoutPrompt
        case 2:
            return .allowReadOnlyWithoutPrompt
        default:
            return .requireEveryCommand
        }
    }

    private func segment(for effort: AIReasoningEffortPreference) -> Int {
        switch effort {
        case .minimal:
            return 0
        case .low:
            return 1
        case .medium:
            return 2
        case .high:
            return 3
        }
    }

    private func reasoningEffort(for segment: Int) -> AIReasoningEffortPreference {
        switch segment {
        case 0:
            return .minimal
        case 1:
            return .low
        case 3:
            return .high
        default:
            return .medium
        }
    }

    private func segment(for compatibilityProtocol: AICompatibilityProtocolPreference) -> Int {
        switch compatibilityProtocol {
        case .chatCompletions:
            return 0
        case .responses:
            return 1
        }
    }

    private func compatibilityProtocol(for segment: Int) -> AICompatibilityProtocolPreference {
        segment == 1 ? .responses : .chatCompletions
    }

    private func title(forAIProvider provider: String) -> String {
        AIProviderProfile.profile(for: provider).displayName
    }

    private func profile(forTitle title: String) -> AIProviderProfile {
        AIProviderProfile.settingsMenuProfiles.first { $0.displayName == title }
            ?? AIProviderProfile.profile(for: title)
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func refreshAISummary() {
        let snapshot = settingsStore.snapshot()
        aiSummaryProviderLabel.stringValue = "\(L10n.Settings.aiProviderSummaryPrefix)：\(title(forAIProvider: snapshot.aiProvider))"
        aiSummaryApprovalLabel.stringValue = "\(L10n.Settings.aiApprovalSummaryPrefix)：\(title(forConfirmationPolicy: snapshot.agentConfirmationPolicy))\(commandPatternSummarySuffix(snapshot))"
        aiSummaryExecutionLabel.stringValue = "\(L10n.Settings.aiExecutionSummaryPrefix)：\(title(forExecutionMode: snapshot.agentExecutionMode))"
        agentApprovalRiskMatrixLabel.stringValue = approvalRiskMatrixText(for: snapshot.agentConfirmationPolicy)
    }

    private func refreshAIModelCatalogControls(status: String? = nil) {
        let snapshot = settingsStore.snapshot()
        let profile = AIProviderProfile.profile(for: snapshot.aiProvider)
        guard profile.usesModelInterface else {
            aiModelCatalogPopup.removeAllItems()
            aiModelCatalogPopup.addItem(withTitle: "规则模式")
            aiModelCatalogPopup.isEnabled = false
            aiRefreshModelsButton.isEnabled = false
            aiAddCustomModelButton.isEnabled = false
            aiReasoningEffortControl.isEnabled = false
            aiCompatibilityProtocolControl.isEnabled = false
            refreshAICustomModelList(models: [], enabled: false)
            aiModelCatalogStatusLabel.stringValue = status ?? "Stacio 规则模式无需模型接口。"
            return
        }
        let models = AppSettings.normalizedAIModelList(
            snapshot.aiCustomModels + [snapshot.aiModel]
        )
        aiModelCatalogPopup.removeAllItems()
        if models.isEmpty {
            aiModelCatalogPopup.addItem(withTitle: "未添加模型")
            aiModelCatalogPopup.isEnabled = false
        } else {
            aiModelCatalogPopup.addItems(withTitles: models)
            aiModelCatalogPopup.selectItem(withTitle: snapshot.aiModel)
            aiModelCatalogPopup.isEnabled = true
        }
        aiRefreshModelsButton.isEnabled = true
        aiAddCustomModelButton.isEnabled = true
        aiReasoningEffortControl.isEnabled = true
        aiCompatibilityProtocolControl.isEnabled = true
        aiReasoningEffortControl.selectedSegment = segment(for: snapshot.aiReasoningEffort)
        aiCompatibilityProtocolControl.selectedSegment = segment(for: snapshot.aiCompatibilityProtocol)
        refreshAICustomModelList(models: snapshot.aiCustomModels, enabled: true)
        aiModelCatalogStatusLabel.stringValue = status ?? "\(profile.displayName)：\(models.count) 个可选模型"
    }

    private func refreshAICustomModelList(models: [String], enabled: Bool) {
        aiCustomModelListStack.arrangedSubviews.forEach { view in
            aiCustomModelListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let normalizedModels = AppSettings.normalizedAIModelList(models)
        if normalizedModels.isEmpty {
            let emptyLabel = NSTextField(labelWithString: L10n.Settings.aiCustomModelListEmpty)
            emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
            emptyLabel.lineBreakMode = .byWordWrapping
            emptyLabel.maximumNumberOfLines = 2
            emptyLabel.setAccessibilityIdentifier("Stacio.Settings.aiCustomModel.empty")
            emptyLabel.translatesAutoresizingMaskIntoConstraints = false
            aiCustomModelListStack.addArrangedSubview(emptyLabel)
            NSLayoutConstraint.activate([
                emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: AppSettingsLayout.controlColumnWidth - 24)
            ])
        } else {
            for model in normalizedModels {
                aiCustomModelListStack.addArrangedSubview(makeAICustomModelRow(model: model, enabled: enabled))
            }
        }
        aiCustomModelListScrollView.isHidden = false
        aiCustomModelListScrollView.contentView.scroll(to: .zero)
        aiCustomModelListScrollView.reflectScrolledClipView(aiCustomModelListScrollView.contentView)
    }

    private func makeAICustomModelRow(model: String, enabled: Bool) -> NSView {
        let label = NSTextField(labelWithString: model)
        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = StacioDesignSystem.theme.primaryTextColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setAccessibilityIdentifier("Stacio.Settings.aiCustomModel.label.\(model)")
        label.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(
            image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: L10n.Settings.aiRemoveCustomModel)
                ?? NSImage(size: NSSize(width: 16, height: 16)),
            target: self,
            action: #selector(aiRemoveCustomModelPressed(_:))
        )
        removeButton.identifier = NSUserInterfaceItemIdentifier(model)
        removeButton.bezelStyle = .inline
        removeButton.isBordered = false
        removeButton.contentTintColor = StacioDesignSystem.theme.secondaryTextColor
        removeButton.isEnabled = enabled
        removeButton.toolTip = L10n.Settings.aiRemoveCustomModel
        removeButton.setAccessibilityLabel("\(L10n.Settings.aiRemoveCustomModel)：\(model)")
        removeButton.setAccessibilityIdentifier("Stacio.Settings.aiCustomModel.remove.\(model)")
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, removeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("Stacio.Settings.aiCustomModel.row.\(model)")

        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: AppSettingsLayout.controlColumnWidth - 24),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: AppSettingsLayout.controlColumnWidth - 72),
            removeButton.widthAnchor.constraint(equalToConstant: 20),
            removeButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        return row
    }

    private func refreshAIProviderFieldAvailability() {
        let usesModelInterface = AIProviderProfile.isModelInterfaceProvider(settingsStore.snapshot().aiProvider)
        [
            aiBaseURLField,
            aiModelField,
            aiAPIKeyField,
            aiMaxRetryCountField,
            aiRequestTimeoutSecondsField,
            aiUserAgentField
        ].forEach { $0.isEnabled = usesModelInterface }
        aiTestConnectionButton.isEnabled = true
    }

    private func providerSelectionStatus(for profile: AIProviderProfile) -> String {
        guard profile.usesModelInterface else {
            return "Stacio 规则模式无需模型接口。"
        }
        return "\(profile.displayName)：请通过供应商管理页获取并选择模型。"
    }

    private func syncCommandPatternFields() {
        let snapshot = settingsStore.snapshot()
        agentCommandAllowPatternsField.stringValue = snapshot.agentCommandAllowPatterns
        agentCommandDenyPatternsField.stringValue = snapshot.agentCommandDenyPatterns
        securityAgentCommandAllowPatternsField.stringValue = snapshot.agentCommandAllowPatterns
        securityAgentCommandDenyPatternsField.stringValue = snapshot.agentCommandDenyPatterns
    }

    private func refreshCustomTerminalThemeLabel() {
        if let theme = settingsStore.snapshot().customTerminalTheme {
            customTerminalThemeLabel.stringValue = "\(L10n.Settings.terminalThemeImportedPrefix)：\(theme.name) · \(theme.sourceFormat.displayName)"
            customTerminalThemeLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        } else {
            customTerminalThemeLabel.stringValue = L10n.Settings.terminalThemeNoCustomTheme
            customTerminalThemeLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        }
    }

    private func refreshTerminalPreview() {
        let theme = resolvedPreviewTheme()
        terminalPreviewView?.layer?.backgroundColor = theme.backgroundColor.cgColor
        terminalPreviewTitleLabel?.stringValue = previewTitleText()
        terminalPreviewTitleLabel?.textColor = theme.foregroundColor.withAlphaComponent(0.82)
        terminalPreviewSampleLabel?.stringValue = terminalPreviewSampleText()
        terminalPreviewSampleLabel?.textColor = theme.foregroundColor
        terminalPreviewSampleLabel?.font = TerminalAppearanceApplier.font(for: settingsStore.snapshot())
        if let palette = terminalPreviewPaletteView {
            palette.subviews.forEach { $0.removeFromSuperview() }
            for swatch in makeThemePaletteStrip(theme: theme).subviews {
                swatch.removeFromSuperview()
                palette.addArrangedSubview(swatch)
            }
        }
    }

    private func refreshTerminalThemeCards() {
        let snapshot = settingsStore.snapshot()
        let selectedID = snapshot.terminalBuiltInThemeID
        for (id, button) in terminalThemeCardButtons {
            let selected = id == TerminalThemeGalleryItemID.systemAdaptive
                ? snapshot.terminalTheme == .system
                : id == selectedID && snapshot.terminalTheme == .dark
            button.layer?.borderWidth = selected ? 2 : 1
            button.layer?.borderColor = (selected ? StacioDesignSystem.theme.accentColor : StacioDesignSystem.theme.separatorColor).cgColor
            terminalThemeCardCheckmarks[id]?.alphaValue = selected ? 1 : 0
        }
    }

    private func resolvedPreviewTheme() -> TerminalColorTheme {
        let settings = settingsStore.snapshot()
        switch settings.terminalTheme {
        case .custom:
            return settings.customTerminalTheme ?? TerminalColorTheme.portDeskDefaultCustom
        case .dark:
            return TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID)
        case .light:
            return TerminalColorTheme.solarizedLight
        case .system:
            return TerminalColorTheme.systemAdaptive(for: view.effectiveAppearance)
        }
    }

    private func previewTitleText() -> String {
        let settings = settingsStore.snapshot()
        switch settings.terminalTheme {
        case .custom:
            return "\(editableCustomTheme().name) · 自定义"
        case .dark:
            return "\(TerminalColorTheme.resolvedBuiltInTheme(id: settings.terminalBuiltInThemeID).name) · 内置主题"
        case .light:
            return "浅色 · 系统文本"
        case .system:
            return "\(L10n.Settings.terminalThemeSystemAdaptiveName) · 跟随 macOS"
        }
    }

    private func terminalPreviewSampleText() -> String {
        "root@stacio:~$ systemctl status nginx\nactive (running)  pid 1842  /usr/sbin/nginx\ndrwxr-xr-x  deploy  /srv/app\nroot@stacio:~$ tail -f /var/log/app.log"
    }

    private func terminalPreviewBackgroundColor() -> NSColor {
        resolvedPreviewTheme().backgroundColor
    }

    private func terminalPreviewForegroundColor() -> NSColor {
        resolvedPreviewTheme().foregroundColor
    }

    private func editableCustomTheme() -> TerminalColorTheme {
        settingsStore.snapshot().customTerminalTheme ?? TerminalColorTheme.portDeskDefaultCustom
    }

    private func refreshFilesSummary() {
        let snapshot = settingsStore.snapshot()
        let directoryFollowState = snapshot.filesDirectoryFollowDefault
            ? L10n.Settings.enabled
            : L10n.Settings.disabled
        let hiddenFilesState = snapshot.filesShowHiddenFilesByDefault
            ? L10n.Settings.enabled
            : L10n.Settings.disabled
        let remoteEditAutoDetectState = snapshot.filesRemoteEditAutoDetectChanges
            ? L10n.Settings.enabled
            : L10n.Settings.disabled
        let transferQueueState = snapshot.filesTransferQueueVisibleByDefault
            ? L10n.Settings.enabled
            : L10n.Settings.disabled
        filesSummaryDirectoryFollowLabel.stringValue = [
            "\(L10n.Settings.filesDirectoryFollowSummaryPrefix)：\(directoryFollowState)",
            "\(L10n.Settings.filesHiddenFilesSummaryPrefix)：\(hiddenFilesState)"
        ].joined(separator: " · ")
        filesSummaryRemoteEditAutoDetectLabel.stringValue = [
            "\(L10n.Settings.filesRemoteEditAutoDetectSummaryPrefix)：\(remoteEditAutoDetectState)",
            "\(L10n.Settings.filesConflictPolicySummaryPrefix)：\(snapshot.filesTransferConflictPolicy.displayName)",
            "\(L10n.Settings.filesTransferQueueSummaryPrefix)：\(transferQueueState)"
        ].joined(separator: " · ")
    }

    private func refreshFilesCacheSummary() {
        do {
            let summary = try cacheMaintenance.cacheSummary()
            filesCacheSizeLabel.stringValue = [
                "\(L10n.Settings.filesCacheSizePrefix)：\(Self.formatByteCount(summary.totalBytes))",
                L10n.Settings.filesCacheDirtySummary(dirtyItemCount: summary.dirtyRemoteEditItemCount)
            ].joined(separator: " · ")
        } catch {
            filesCacheSizeLabel.stringValue = "\(L10n.Settings.filesCacheSizePrefix)：-"
        }
    }

    fileprivate static func formatByteCount(_ bytes: UInt64) -> String {
        if bytes < 1_000 {
            return "\(bytes) B"
        }
        if bytes < 1_000_000 {
            return String(format: "%.0f KB", Double(bytes) / 1_000.0)
        }
        if bytes < 1_000_000_000 {
            let megabytes = Double(bytes) / 1_000_000.0
            return megabytes.rounded() == megabytes
                ? String(format: "%.0f MB", megabytes)
                : String(format: "%.1f MB", megabytes)
        }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000.0)
    }

    private func refreshMetricsSummary() {
        let snapshot = settingsStore.snapshot()
        let failureState = snapshot.deviceMetricsKeepLastSnapshotOnFailure
            ? "失败时保留上次成功数据"
            : "失败时显示错误"
        let networkState = snapshot.deviceMetricsShowNetworkSection ? "网络开启" : "网络关闭"
        let diskState = snapshot.deviceMetricsShowDiskSection
            ? "磁盘 \(snapshot.deviceMetricsDiskMountLimit) 个"
            : "磁盘关闭"
        let virtualNetworkState = snapshot.deviceMetricsHideVirtualNetworkInterfaces
            ? "过滤虚拟网卡"
            : "显示全部网卡"
        let displayLocation = snapshot.deviceMetricsDisplayLocation == .terminalBottom
            ? L10n.Settings.deviceMetricsDisplayLocationTerminalBottom
            : L10n.Settings.deviceMetricsDisplayLocationFloating
        let alertState = snapshot.deviceMetricsAlertEnabled
            ? "告警开启：CPU \(snapshot.deviceMetricsCPUAlertThresholdPercent)% / 内存 \(snapshot.deviceMetricsMemoryAlertThresholdPercent)% / 磁盘 \(snapshot.deviceMetricsDiskAlertThresholdPercent)% · 连续 \(snapshot.deviceMetricsAlertConsecutiveRefreshCount) 次"
            : "告警关闭"
        metricsSummaryCollectionLabel.stringValue = [
            "\(L10n.Settings.metricsCollectionSummaryPrefix)：每 \(snapshot.deviceMetricsRefreshIntervalSeconds) 秒",
            failureState,
            networkState,
            diskState,
            alertState
        ].joined(separator: " · ")
        metricsSummaryDisplayLabel.stringValue = [
            "\(L10n.Settings.deviceMetricsDisplayLocation)：\(displayLocation)",
            "\(L10n.Settings.metricsDisplaySummaryPrefix)：曲线 \(snapshot.deviceMetricsHistorySampleCount) 点",
            virtualNetworkState
        ].joined(separator: " · ")
    }

    private func refreshSecuritySummary() {
        let snapshot = settingsStore.snapshot()
        securitySummaryApprovalLabel.stringValue = "\(L10n.Settings.securityApprovalSummaryPrefix)：\(title(forConfirmationPolicy: snapshot.agentConfirmationPolicy))\(commandPatternSummarySuffix(snapshot))"
        securitySummaryCredentialLabel.stringValue = L10n.Settings.securityCredentialSummary
        let logSummary = snapshot.diagnosticsIncludeAppLogs
            ? "日志 \(snapshot.diagnosticsAppLogLineLimit) 行"
            : "不包含应用日志"
        securitySummaryAuditLabel.stringValue = "\(L10n.Settings.securityAuditSummary) · 最近 \(snapshot.diagnosticsAuditExportLimit) 条 · \(logSummary)"
        securityApprovalRiskMatrixLabel.stringValue = approvalRiskMatrixText(for: snapshot.agentConfirmationPolicy)
    }

    private func refreshCredentialCenter() {
        do {
            credentialCenterRecords = try credentialCenterStore?.listCredentials() ?? []
            credentialCenterListPopup.removeAllItems()
            if credentialCenterRecords.isEmpty {
                credentialCenterListPopup.addItem(withTitle: L10n.Settings.credentialCenterEmpty)
                credentialCenterListPopup.isEnabled = false
                credentialCenterDeleteButton.isEnabled = false
            } else {
                credentialCenterListPopup.addItems(withTitles: credentialCenterRecords.map(credentialCenterTitle(for:)))
                credentialCenterListPopup.isEnabled = true
                credentialCenterDeleteButton.isEnabled = true
            }
            credentialCenterSummaryLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
            refreshCredentialCenterSummary()
            securitySummaryCredentialLabel.stringValue = credentialCenterRecords.isEmpty
                ? L10n.Settings.securityCredentialSummary
                : "\(L10n.Settings.securityCredentialSummary) · \(credentialCenterRecords.count)"
        } catch {
            credentialCenterRecords = []
            credentialCenterListPopup.removeAllItems()
            credentialCenterListPopup.addItem(withTitle: L10n.Settings.credentialCenterUnavailable)
            credentialCenterListPopup.isEnabled = false
            credentialCenterDeleteButton.isEnabled = false
            credentialCenterSummaryLabel.textColor = StacioDesignSystem.theme.dangerColor
            credentialCenterSummaryLabel.stringValue = "\(L10n.Settings.aiConnectionFailedPrefix)\(RuntimeDiagnosticFormatter.userMessage(for: error))"
        }
        updateCredentialCenterAddButtonState()
    }

    private func refreshCredentialCenterSummary() {
        guard credentialCenterRecords.isEmpty == false else {
            credentialCenterSummaryLabel.stringValue = L10n.Settings.credentialCenterEmptySummary
            return
        }
        let selectedIndex = credentialCenterListPopup.indexOfSelectedItem
        let selected = credentialCenterRecords.indices.contains(selectedIndex)
            ? credentialCenterRecords[selectedIndex]
            : credentialCenterRecords[0]
        credentialCenterSummaryLabel.stringValue = "\(credentialCenterRecords.count) 个凭据引用 · 当前：\(selected.kind) · \(selected.keychainAccount)"
    }

    private func updateCredentialCenterAddButtonState() {
        let account = credentialCenterNewAccountField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = credentialCenterNewSecretField.stringValue
        let canAddCredential = account.isEmpty == false
            && secret.isEmpty == false
            && credentialCenterStore != nil
        credentialCenterAddPasswordButton.isEnabled = canAddCredential
        credentialCenterAddPrivateKeyPassphraseButton.isEnabled = canAddCredential
        credentialCenterAddTokenButton.isEnabled = canAddCredential
    }

    private func credentialCenterTitle(for record: CredentialRecord) -> String {
        let label = record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? record.kind
            : record.label
        return "\(label) · \(record.kind) · \(record.keychainAccount)"
    }

    private func commandPatternSummarySuffix(_ settings: AppSettings) -> String {
        var parts: [String] = []
        if settings.agentCommandAllowPatterns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("自动放行")
        }
        if settings.agentCommandDenyPatterns.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            parts.append("禁止优先")
        }
        guard parts.isEmpty == false else {
            return ""
        }
        return " · \(parts.joined(separator: "/"))"
    }

    private func title(forConfirmationPolicy policy: AgentConfirmationPolicyPreference) -> String {
        switch policy {
        case .allowAllWithoutPrompt:
            return L10n.Settings.allowAllCommands
        case .allowLowRiskWithoutPrompt:
            return L10n.Settings.allowLowRisk
        case .allowReadOnlyWithoutPrompt:
            return L10n.Settings.allowReadOnly
        case .requireEveryCommand:
            return L10n.Settings.requireEveryCommand
        }
    }

    private func approvalRiskMatrixText(for policy: AgentConfirmationPolicyPreference) -> String {
        let authorizationPolicy = policy.authorizationPolicy
        let rows: [(String, AgentActionRisk)] = [
            ("只读", .readOnly),
            ("普通写入", .write),
            ("网络操作", .network),
            ("破坏性", .destructive)
        ]
        let summary = rows
            .map { title, risk in
                let decision = authorizationPolicy.requiresConfirmation(for: risk)
                    ? "需要确认"
                    : "自动放行"
                return "\(title)：\(decision)"
            }
            .joined(separator: " · ")
        return "审批矩阵：\(summary)"
    }

    private func title(forExecutionMode mode: AgentExecutionModePreference) -> String {
        switch mode {
        case .visibleTerminal:
            return L10n.Settings.visibleTerminal
        case .backgroundTask:
            return L10n.Settings.backgroundTask
        }
    }
}

private final class UncheckedAIAssistantConnectionTesterBox: @unchecked Sendable {
    let value: AIAssistantConnectionTesting

    init(_ value: AIAssistantConnectionTesting) {
        self.value = value
    }
}

private final class AppSettingsRootView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 980, height: 680)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let window {
            StacioDesignSystem.refreshWindowDynamicColors(window)
        }
        onEffectiveAppearanceChange?()
    }
}

private final class AppSettingsCenteredLabelCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredTextRect(for: rect)
    }

    private func centeredTextRect(for rect: NSRect) -> NSRect {
        let textHeight = min(cellSize.height, rect.height)
        let yOffset = floor((rect.height - textHeight) / 2)
        return NSRect(
            x: rect.minX,
            y: rect.minY + yOffset,
            width: rect.width,
            height: textHeight
        )
    }
}

private class AppSettingsInsetTextFieldCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 7

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    private func adjustedTextRect(for rect: NSRect) -> NSRect {
        let width = max(0, rect.width - horizontalInset * 2)
        let activeFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        let targetHeight = min(
            max(ceil(activeFont.ascender - activeFont.descender + activeFont.leading), 18),
            rect.height
        )
        return NSRect(
            x: rect.minX + horizontalInset,
            y: rect.midY - targetHeight / 2,
            width: width,
            height: targetHeight
        )
    }
}

private final class AppSettingsInsetSecureTextFieldCell: NSSecureTextFieldCell {
    private let horizontalInset: CGFloat = 7

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        adjustedTextRect(for: rect)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: rect,
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
        textObj.frame = adjustedTextRect(for: rect)
    }

    private func adjustedTextRect(for rect: NSRect) -> NSRect {
        let width = max(0, rect.width - horizontalInset * 2)
        let activeFont = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        let targetHeight = min(
            max(ceil(activeFont.ascender - activeFont.descender + activeFont.leading), 18),
            rect.height
        )
        return NSRect(
            x: rect.minX + horizontalInset,
            y: rect.midY - targetHeight / 2,
            width: width,
            height: targetHeight
        )
    }
}

private final class UncheckedAIModelCatalogLoaderBox: @unchecked Sendable {
    let value: AIModelCatalogLoading

    init(_ value: AIModelCatalogLoading) {
        self.value = value
    }
}

private final class UncheckedAIApiKeyStoreBox: @unchecked Sendable {
    let value: AIApiKeyStoring

    init(_ value: AIApiKeyStoring) {
        self.value = value
    }
}
