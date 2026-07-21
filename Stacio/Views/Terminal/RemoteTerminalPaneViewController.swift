import AppKit
import StacioCoreBindings
import StacioAgentBridge
import SwiftTerm

public protocol RemoteTerminalBridging: AnyObject {
    func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus
    func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch
    func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime
    func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws
    func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus
}

public enum RemoteTerminalLifecycleState: Equatable {
    case connecting
    case running
    case disconnected
    case reconnecting
    case closed
}

public enum RemoteTerminalConnectionKind: Equatable {
    case ssh
    case serial
    case telnet
}

public struct SessionAutomationPolicy: Equatable, Sendable {
    public let environment: String
    public let aiExecutionPolicy: String
    public let startupCommand: String?
    public let environmentVariables: [String]
    public let connectTimeoutMs: UInt32?
    public let postConnectScript: String?

    public init(
        environment: String = "development",
        aiExecutionPolicy: String = "inherit",
        startupCommand: String? = nil,
        environmentVariables: [String] = [],
        connectTimeoutMs: UInt32? = nil,
        postConnectScript: String? = nil
    ) {
        self.environment = Self.normalizedEnvironment(environment)
        self.aiExecutionPolicy = Self.normalizedAIPolicy(aiExecutionPolicy)
        self.startupCommand = Self.normalizedOptionalString(startupCommand)
        self.environmentVariables = Self.normalizedEnvironmentVariables(environmentVariables)
        self.connectTimeoutMs = Self.normalizedConnectTimeoutMs(connectTimeoutMs)
        self.postConnectScript = Self.normalizedOptionalString(postConnectScript)
    }

    public static let `default` = SessionAutomationPolicy()

    public static func fromConfigJSON(_ configJSON: String?) -> SessionAutomationPolicy {
        guard let configJSON,
              let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .default
        }
        return SessionAutomationPolicy(
            environment: object["environment"] as? String ?? "development",
            aiExecutionPolicy: object["aiExecutionPolicy"] as? String ?? "inherit",
            startupCommand: object["startupCommand"] as? String,
            environmentVariables: Self.environmentVariables(from: object["environmentVariables"]),
            connectTimeoutMs: Self.connectTimeoutMs(from: object["connectTimeoutMs"]),
            postConnectScript: object["postConnectScript"] as? String
        )
    }

    var postConnectInputBytes: [UInt8]? {
        guard let postConnectScript else {
            return nil
        }
        let command = postConnectScript.hasSuffix("\n")
            ? postConnectScript
            : "\(postConnectScript)\n"
        return Array(command.utf8)
    }

    public var startupPlanShellLine: String? {
        let parts = environmentVariables + [startupCommand].compactMap { $0 }
        guard parts.isEmpty == false else {
            return nil
        }
        return parts.joined(separator: " ")
    }

    private static func normalizedEnvironment(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "production", "prod":
            return "production"
        case "staging", "stage":
            return "staging"
        default:
            return "development"
        }
    }

    private static func normalizedAIPolicy(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "disabled", "deny", "off":
            return "disabled"
        case "commandcard", "command_card", "suggest":
            return "commandCard"
        case "readonlyauto", "read_only_auto", "readonly":
            return "readOnlyAuto"
        case "requireeverycommand", "require_every_command", "confirm":
            return "requireEveryCommand"
        default:
            return "inherit"
        }
    }

    private static func normalizedOptionalString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedEnvironmentVariables(_ values: [String]) -> [String] {
        values.compactMap { rawValue in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else {
                return nil
            }
            return trimmed
        }
    }

    private static func environmentVariables(from value: Any?) -> [String] {
        if let values = value as? [String] {
            return normalizedEnvironmentVariables(values)
        }
        if let rawValue = value as? String {
            return normalizedEnvironmentVariables(rawValue.components(separatedBy: .newlines))
        }
        return []
    }

    private static func connectTimeoutMs(from value: Any?) -> UInt32? {
        if let number = value as? NSNumber {
            return normalizedConnectTimeoutMs(number.uint32Value)
        }
        if let rawValue = value as? String,
           let milliseconds = UInt32(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return normalizedConnectTimeoutMs(milliseconds)
        }
        return nil
    }

    private static func normalizedConnectTimeoutMs(_ value: UInt32?) -> UInt32? {
        SSHConnectionDefaults.normalizedConnectTimeoutMs(value)
    }
}

public enum RemoteTerminalLifecycleError: Error, LocalizedError {
    case reconnectUnavailable
    case reconnectFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .reconnectUnavailable:
            return L10n.TerminalLifecycle.reconnectUnavailable
        case let .reconnectFailed(message):
            return message
        }
    }
}

@MainActor
public protocol RemoteTerminalReconnecting: AnyObject {
    var liveSessionContext: TunnelLiveSessionContext? { get }

    func reconnectRemoteTerminal(title: String) throws -> LiveShellStatus
    func reconnectRemoteTerminalAutomatically(title: String) throws -> LiveShellStatus
    func automaticReconnectDelaySeconds() -> TimeInterval
}

@MainActor
public protocol RemoteTerminalBackgroundReconnecting: RemoteTerminalReconnecting {
    func reconnectRemoteTerminalInBackground(
        title: String,
        automatically: Bool,
        completion: @escaping @MainActor (Result<LiveShellStatus, Error>) -> Void
    )
    func cancelPendingReconnects()
}

@MainActor
public extension RemoteTerminalReconnecting {
    var liveSessionContext: TunnelLiveSessionContext? { nil }

    func reconnectRemoteTerminalAutomatically(title: String) throws -> LiveShellStatus {
        try reconnectRemoteTerminal(title: title)
    }

    func automaticReconnectDelaySeconds() -> TimeInterval {
        0
    }
}

@MainActor
public extension RemoteTerminalBackgroundReconnecting {
    func cancelPendingReconnects() {}
}

public final class CoreBridgeRemoteTerminalBridge: RemoteTerminalBridging {
    public init() {}

    public func pollLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        try CoreBridge.pollLiveSSHShell(runtimeID: runtimeID)
    }

    public func takeTerminalOutputBatch(runtimeID: String) throws -> TerminalOutputBatch {
        try CoreBridge.takeTerminalOutputBatch(runtimeID: runtimeID)
    }

    public func setTerminalOutputPaused(runtimeID: String, paused: Bool) throws -> TerminalRuntime {
        try CoreBridge.setTerminalOutputPaused(runtimeID: runtimeID, paused: paused)
    }

    public func setLiveShellKeepaliveInterval(runtimeID: String, seconds: UInt32) throws {
        try CoreBridge.setLiveShellKeepaliveInterval(runtimeID: runtimeID, seconds: seconds)
    }

    public func closeLiveSSHShell(runtimeID: String) throws -> LiveShellStatus {
        try CoreBridge.closeLiveSSHShell(runtimeID: runtimeID)
    }
}

public final class RemoteTerminalPaneViewController: NSViewController, TerminalViewDelegate {
    private struct PendingSilentInputEchoFilter {
        let patterns: [[UInt8]]
        let expiresAt: Date
    }

    private struct SilentInputEchoFilterResult {
        let bytes: [UInt8]
        let didRemoveEcho: Bool
    }

    private static let terminalEchoRestoreInput = Array("stty echo 2>/dev/null\n".utf8)
    private static let outputPollInterval: TimeInterval = 0.016
    private static let immediateOutputDrainPassLimit = 8
    private static let immediateOutputDrainFollowUpLimit = 60
    private static let immediateOutputDrainFollowUpDelay: TimeInterval = 0.01

    public private(set) var runtimeID: String
    public let terminalTitle: String
    public let connectionKind: RemoteTerminalConnectionKind
    var reconnecterForWorkspace: RemoteTerminalReconnecting? { reconnecter }
    public private(set) var liveSessionContext: TunnelLiveSessionContext?
    public private(set) var automationPolicy: SessionAutomationPolicy
    public private(set) var currentRemoteDirectory: String = "~"
    public let terminalView: StacioRemoteTerminalView
    public var keyboardFocusView: NSView { terminalView }
    public private(set) var lifecycleState: RemoteTerminalLifecycleState = .running
    public var onUserInput: ((RemoteTerminalPaneViewController, [UInt8]) -> Bool)?
    public var onMultiExecPauseChanged: ((RemoteTerminalPaneViewController, Bool) -> Void)?
    public var onRequestClose: ((RemoteTerminalPaneViewController) -> Void)?
    public var onRequestSaveOutput: ((RemoteTerminalPaneViewController) -> Void)?
    public var onRuntimeAttached: ((RemoteTerminalPaneViewController, LiveShellStatus, TunnelLiveSessionContext?) -> Void)?
    public var onRuntimeReattached: ((RemoteTerminalPaneViewController, String, LiveShellStatus, TunnelLiveSessionContext?) -> Void)?
    public var onRemoteDirectoryChanged: ((RemoteTerminalPaneViewController, String) -> Void)?
    public var onAIContextRequest: ((TerminalAIContextRequest) -> Void)?
    public var onMultiExecPresentationChanged: ((RemoteTerminalPaneViewController) -> Void)?
    public var onCommandSubmitted: ((RemoteTerminalPaneViewController, String) -> Void)?
    public var onCommandFinished: ((RemoteTerminalPaneViewController) -> Void)?
    public private(set) var commandCompletionGeneration: UInt64 = 0
    private var agentInteractionLocked = false
    public var onUploadDroppedFiles: ((String, [String]) -> Void)?
    public var canAcceptDroppedLocalFiles: Bool {
        connectionKind == .ssh && liveSessionContext != nil
    }

    private let bridge: RemoteTerminalBridging
    private let reconnecter: RemoteTerminalReconnecting?
    private let startupBanner: String?
    private let startsPollingAutomatically: Bool
    private let silentInputEchoTimeout: TimeInterval
    private let settingsStore: AppSettingsStore
    private let transcriptRecorder: TranscriptRecorder
    private let eventSink: TerminalEventSink
    private let linkOpener: TerminalLinkOpening
    private let injectedPathCompletionProvider: TerminalPathCompletionProviding?
    private let agentTraceController = TerminalTraceController()
    private let commandInputObserver = TerminalCommandInputObserver()
    private let commandHistoryInputBuffer = TerminalCommandHistoryInputBuffer()
    private var commandSuggestionHistoryCommands: [String] = []
    private let commandHintOverlay = TerminalCommandHintOverlayView()
    private let agentTraceOverlay = TerminalAgentTraceOverlayView(frame: .zero)
    private let agentInteractionGlow = TerminalAgentInteractionGlowView(frame: .zero)
    private lazy var liveRemotePathCompletionProvider: RemoteTerminalPathCompletionProvider = {
        let provider = RemoteTerminalPathCompletionProvider(
            liveSessionContextProvider: { [weak self] in
                self?.liveSessionContext
            },
            currentDirectoryProvider: { [weak self] in
                self?.currentRemoteDirectory ?? "~"
            }
        )
        provider.onCandidatesUpdated = { [weak self] in
            self?.refreshCommandCompletionFromPathCache()
        }
        return provider
    }()
    private let lineInfoGutter = TerminalLineInfoGutterView()
    private lazy var terminalSearchController = TerminalSearchController(
        terminalView: terminalView,
        focusView: terminalView
    )
    private var terminalBottomToContainerConstraint: NSLayoutConstraint?
    private var terminalBottomToCommandHintConstraint: NSLayoutConstraint?
    private var terminalLeadingToContainerConstraint: NSLayoutConstraint?
    private var terminalLeadingToLineInfoConstraint: NSLayoutConstraint?
    private var lineInfoGutterWidthConstraint: NSLayoutConstraint?
    private var terminalTopToContainerConstraint: NSLayoutConstraint?
    private var terminalTopWithPaddingConstraint: NSLayoutConstraint?
    private var terminalTrailingToContainerConstraint: NSLayoutConstraint?
    private var terminalTrailingWithPaddingConstraint: NSLayoutConstraint?
    private var commandHintLeadingConstraint: NSLayoutConstraint?
    private var commandHintBottomConstraint: NSLayoutConstraint?
    private var commandHintWidthConstraint: NSLayoutConstraint?
    private lazy var terminalContextMenuController = TerminalContextMenuController(
        runtimeID: runtimeID,
        paste: { [weak self] in
            self?.pasteClipboard()
        },
        askAI: { [weak self] request in
            self?.onAIContextRequest?(request)
        }
    )
    private var outputPollTimer: Timer?
    private var immediateOutputDrainScheduled = false
    private var immediateOutputDrainFollowUpBurstsRemaining = 0
    private var immediateOutputDrainFollowUpWorkItem: DispatchWorkItem?
    private var isPollingRemoteOutput = false
    private var pendingTerminalResize: (runtimeID: String, cols: Int, rows: Int)?
    private var isSendingTerminalResize = false
    private var automaticReconnectWorkItem: DispatchWorkItem?
    private var initialTransientNetworkFailureCount = 0
    private var reconnectGeneration: UInt64 = 0
    private var didClose = false
    private var didDisplayStartupBanner = false
    private var didWritePostConnectScript = false
    private var hasEstablishedRuntime: Bool
    private var isFeedingRemoteOutput = false
    private var remoteFeedCurrentDirectories: Set<String> = []
    private var settingsObserver: NSObjectProtocol?
    private var remoteInputLineBuffer: [UInt8] = []
    private var remoteInputLineUsedCompletion = false
    private var remoteInputLineAnchorCaretFrame: NSRect?
    private var remoteInputLineAnchorLength = 0
    private var remoteCompletionInputLine = ""
    private var osc7OutputBuffer: [UInt8] = []
    private var pendingSilentInputEchoFilters: [PendingSilentInputEchoFilter] = []
    private var silentInputEchoRecoveryDeadline: Date?
    private var silentInputEchoRecoveryTimeoutWorkItem: DispatchWorkItem?
    private var remotePromptOutputBuffer = ""
    private var previousRemoteDirectory: String?
    private var remoteDirectoryStack: [String] = []
    private let lifecycleBar = NSStackView()
    private let lifecycleLabel = NSTextField(labelWithString: "")
    private let reconnectButton = NSButton(
        title: L10n.TerminalLifecycle.reconnect,
        target: nil,
        action: nil
    )
    private let outputProtectionBar = NSStackView()
    private let outputProtectionLabel = NSTextField(labelWithString: "")
    private let outputProtectionToggleButton = NSButton(
        title: L10n.TerminalOutputProtection.pause,
        target: nil,
        action: nil
    )
    private var isOutputPaused = false
    private var outputProtectionActive = false
    private var outputProtectionDroppedByteCount: UInt32 = 0
    private var outputProtectionBufferedByteCount: UInt32 = 0
    private var multiExecModeEnabled = false
    public private(set) var isMultiExecPaused = false
    public var isMultiExecModeEnabled: Bool { multiExecModeEnabled }

    public init(
        runtimeID: String,
        title: String,
        connectionKind: RemoteTerminalConnectionKind = .ssh,
        liveSessionContext: TunnelLiveSessionContext? = nil,
        eventSink: TerminalEventSink,
        startupBanner: String? = nil,
        bridge: RemoteTerminalBridging = CoreBridgeRemoteTerminalBridge(),
        reconnecter: RemoteTerminalReconnecting? = nil,
        transcriptRecorder: TranscriptRecorder = TranscriptRecorder(),
        settingsStore: AppSettingsStore = .shared,
        automationPolicy: SessionAutomationPolicy = .default,
        linkOpener: TerminalLinkOpening? = nil,
        startsPollingAutomatically: Bool = true,
        silentInputEchoTimeout: TimeInterval = 5.0,
        pathCompletionProvider: TerminalPathCompletionProviding? = nil
    ) {
        self.runtimeID = runtimeID
        self.terminalTitle = title
        self.connectionKind = connectionKind
        self.liveSessionContext = liveSessionContext
        self.eventSink = eventSink
        self.startupBanner = startupBanner
        self.bridge = bridge
        self.reconnecter = reconnecter
        self.transcriptRecorder = transcriptRecorder
        self.settingsStore = settingsStore
        self.automationPolicy = automationPolicy
        self.linkOpener = linkOpener ?? WorkspaceTerminalLinkOpener.shared
        self.injectedPathCompletionProvider = pathCompletionProvider
        self.startsPollingAutomatically = startsPollingAutomatically
        self.silentInputEchoTimeout = max(silentInputEchoTimeout, 0)
        self.terminalView = StacioRemoteTerminalView(frame: .zero)
        self.hasEstablishedRuntime = runtimeID.hasPrefix("pending_") == false
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = TerminalFocusContainerView()
        container.onEffectiveAppearanceChanged = { [weak self] in
            self?.terminalEffectiveAppearanceDidChange()
        }
        container.acceptsLocalFileDrops = { [weak self] in
            self?.canAcceptDroppedLocalFiles ?? false
        }
        container.localFileDropHandler = { [weak self] localPaths in
            self?.handleDroppedLocalFilePaths(localPaths)
        }
        container.translatesAutoresizingMaskIntoConstraints = false

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.terminalDelegate = self
        terminalView.fontZoomSettingsStore = settingsStore
        terminalView.notifyUpdateChanges = true
        terminalView.acceptsLocalFileDrops = { [weak self] in
            self?.canAcceptDroppedLocalFiles ?? false
        }
        terminalView.localFileDropHandler = { [weak self] localPaths in
            self?.handleDroppedLocalFilePaths(localPaths)
        }
        terminalView.onSearchViewportChanged = { [weak self] in
            guard let self else { return }
            self.terminalSearchController.terminalContentDidChange()
            self.refreshLineInfoGutter()
        }
        TerminalAppearanceApplier.apply(settings: settingsStore.snapshot(), to: terminalView)
        observeSettingsChanges()
        syncLiveShellKeepaliveInterval(settingsStore.snapshot())
        terminalView.contextMenuProvider = { [weak self] selectedText in
            self?.terminalContextMenuController.makeMenu(selectedText: selectedText)
        }
        commandHintOverlay.onVisibilityChanged = { [weak self] visible in
            self?.setCommandHintOverlayVisible(visible)
        }
        agentTraceOverlay.onControlAction = { [weak self] requestID, action in
            guard let self else { return }
            TerminalAgentTaskControlNotification.post(
                runtimeID: self.runtimeID,
                requestID: requestID,
                action: action
            )
        }

        container.addSubview(terminalView)
        container.terminalFocusView = terminalView
        container.addSubview(lineInfoGutter)
        container.addSubview(agentInteractionGlow, positioned: .above, relativeTo: terminalView)
        configureLifecycleBar()
        configureOutputProtectionBar()
        container.addSubview(lifecycleBar)
        container.addSubview(outputProtectionBar)
        container.addSubview(commandHintOverlay)
        container.addSubview(agentTraceOverlay)
        terminalSearchController.install(in: container, overlaying: terminalView)
        let terminalBottomToContainer = terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        let terminalBottomToCommandHint = terminalView.bottomAnchor.constraint(
            equalTo: commandHintOverlay.topAnchor,
            constant: -8
        )
        let terminalLeadingToContainer = terminalView.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let terminalLeadingToLineInfo = terminalView.leadingAnchor.constraint(equalTo: lineInfoGutter.trailingAnchor, constant: 6)
        let lineInfoGutterWidth = lineInfoGutter.widthAnchor.constraint(equalToConstant: 0)
        let terminalTopToContainer = terminalView.topAnchor.constraint(equalTo: container.topAnchor)
        let terminalTopWithPadding = terminalView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12)
        let terminalTrailingToContainer = terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let terminalTrailingWithPadding = terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12)
        let commandHintLeading = commandHintOverlay.leadingAnchor.constraint(
            equalTo: container.leadingAnchor,
            constant: TerminalCommandHintOverlayLayout.containerMargin
        )
        let commandHintBottom = commandHintOverlay.bottomAnchor.constraint(
            equalTo: container.bottomAnchor,
            constant: -TerminalCommandHintOverlayLayout.containerMargin
        )
        let commandHintWidth = commandHintOverlay.widthAnchor.constraint(
            equalToConstant: TerminalCommandHintOverlayLayout.completionPreferredWidth
        )
        let agentTraceLeading = agentTraceOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8)
        let agentTraceTop = agentTraceOverlay.topAnchor.constraint(equalTo: lifecycleBar.bottomAnchor, constant: 6)
        agentTraceOverlay.onDragOffsetChanged = { [weak container, weak agentTraceOverlay, weak lifecycleBar] offset in
            guard let container, let agentTraceOverlay, let lifecycleBar else { return }
            let maximumX = max(8, container.bounds.width - agentTraceOverlay.bounds.width - 8)
            let availableHeight = max(0, container.bounds.height - lifecycleBar.frame.maxY - 14)
            let maximumTopOffset = max(6, availableHeight - agentTraceOverlay.bounds.height + 6)
            agentTraceLeading.constant = min(max(8, 8 + offset.x), maximumX)
            agentTraceTop.constant = min(max(6, 6 + offset.y), maximumTopOffset)
        }
        terminalBottomToContainerConstraint = terminalBottomToContainer
        terminalBottomToCommandHintConstraint = terminalBottomToCommandHint
        terminalLeadingToContainerConstraint = terminalLeadingToContainer
        terminalLeadingToLineInfoConstraint = terminalLeadingToLineInfo
        lineInfoGutterWidthConstraint = lineInfoGutterWidth
        terminalTopToContainerConstraint = terminalTopToContainer
        terminalTopWithPaddingConstraint = terminalTopWithPadding
        terminalTrailingToContainerConstraint = terminalTrailingToContainer
        terminalTrailingWithPaddingConstraint = terminalTrailingWithPadding
        commandHintLeadingConstraint = commandHintLeading
        commandHintBottomConstraint = commandHintBottom
        commandHintWidthConstraint = commandHintWidth
        NSLayoutConstraint.activate([
            terminalLeadingToContainer,
            terminalTrailingToContainer,
            terminalTopToContainer,
            terminalBottomToContainer,
            agentInteractionGlow.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            agentInteractionGlow.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            agentInteractionGlow.topAnchor.constraint(equalTo: terminalView.topAnchor),
            agentInteractionGlow.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            lineInfoGutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lineInfoGutter.topAnchor.constraint(equalTo: terminalView.topAnchor),
            lineInfoGutter.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor),
            lineInfoGutterWidth,
            lifecycleBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            lifecycleBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            lifecycleBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            outputProtectionBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            outputProtectionBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            outputProtectionBar.leadingAnchor.constraint(greaterThanOrEqualTo: lifecycleBar.trailingAnchor, constant: 12),
            commandHintLeading,
            commandHintOverlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -48),
            commandHintBottom,
            commandHintOverlay.widthAnchor.constraint(
                lessThanOrEqualToConstant: TerminalCommandHintOverlayLayout.submittedPreferredMaxWidth
            ),
            agentTraceLeading,
            agentTraceOverlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            agentTraceTop,
            agentTraceOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        applyTerminalRuntimeSettings(settingsStore.snapshot())

        view = container
        displayStartupBannerIfNeeded()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        positionCommandCompletionOverlayIfNeeded(requiresLayout: false)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        focusTerminalViewForKeyboardInput()
        startOutputPollingIfNeeded()
        writePostConnectScriptIfNeeded()
    }

    private func startOutputPollingIfNeeded() {
        guard startsPollingAutomatically,
              lifecycleState == .running,
              outputPollTimer == nil
        else { return }
        let timer = Timer(timeInterval: Self.outputPollInterval, repeats: true) { [weak self] _ in
            self?.pollRemoteOutputInBackground()
        }
        RunLoop.main.add(timer, forMode: .common)
        outputPollTimer = timer
    }

    private func pollRemoteOutputInBackground(
        maximumPasses: Int = 1,
        allowWhenAgentInteractionLocked: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard didClose == false,
              lifecycleState == .running,
              (allowWhenAgentInteractionLocked || agentInteractionLocked == false),
              isPollingRemoteOutput == false
        else {
            completion?(false)
            return
        }
        isPollingRemoteOutput = true
        let polledRuntimeID = runtimeID
        let bridge = bridge
        let passCount = max(1, maximumPasses)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [Result<(LiveShellStatus, TerminalOutputBatch), Error>] = []
            for _ in 0..<passCount {
                do {
                    let status = try bridge.pollLiveSSHShell(runtimeID: polledRuntimeID)
                    guard status.runtimeId == polledRuntimeID else {
                        break
                    }
                    let batch = try bridge.takeTerminalOutputBatch(runtimeID: polledRuntimeID)
                    guard batch.runtimeId == polledRuntimeID else {
                        break
                    }
                    results.append(.success((status, batch)))
                    guard status.status == "running", batch.bytes.isEmpty == false else {
                        break
                    }
                } catch {
                    results.append(.failure(error))
                    break
                }
            }
            RunLoop.main.perform(inModes: [.common]) {
                guard let self else { return }
                self.isPollingRemoteOutput = false
                guard self.didClose == false, self.runtimeID == polledRuntimeID else {
                    completion?(false)
                    return
                }
                var didReceiveOutput = false
                processResults: for result in results {
                    switch result {
                    case let .success((status, batch)):
                        guard status.runtimeId == polledRuntimeID, batch.runtimeId == polledRuntimeID else {
                            break processResults
                        }
                    self.updateOutputProtectionStatus(
                        protectionActive: batch.protectionActive,
                        droppedByteCount: batch.droppedByteCount,
                        bufferedByteCount: batch.bufferedByteCount
                    )
                    if !batch.bytes.isEmpty {
                        self.feedRemoteOutput(Array(batch.bytes), applySemanticHighlighting: batch.protectionActive == false)
                        didReceiveOutput = true
                    }
                    if status.status != "running" {
                        self.stopOutputPolling()
                        self.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(status.diagnostic))
                        completion?(didReceiveOutput)
                        return
                    }
                    case let .failure(error):
                        guard Self.isTransientPollError(error) == false else {
                            break processResults
                        }
                        self.stopOutputPolling()
                        self.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
                        completion?(didReceiveOutput)
                        return
                    }
                }
                completion?(didReceiveOutput)
            }
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        stopOutputPolling()
    }

    private func stopOutputPolling() {
        outputPollTimer?.invalidate()
        outputPollTimer = nil
        cancelImmediateOutputDrain()
    }

    private func cancelImmediateOutputDrain() {
        immediateOutputDrainFollowUpWorkItem?.cancel()
        immediateOutputDrainFollowUpWorkItem = nil
        immediateOutputDrainScheduled = false
        immediateOutputDrainFollowUpBurstsRemaining = 0
    }

    public func feedRemoteOutput(_ bytes: [UInt8], applySemanticHighlighting: Bool = true) {
        let filteredOutput = filterPendingSilentInputEcho(from: bytes)
        let visibleBytes = filteredOutput.bytes
        guard visibleBytes.isEmpty == false else {
            if filteredOutput.didRemoveEcho {
                finishSilentInputEchoRecovery(restoreTerminalEcho: false)
            }
            return
        }
        transcriptRecorder.append(bytes: visibleBytes)
        let candidateOSC7Bytes = Array((osc7OutputBuffer + visibleBytes).suffix(4_096))
        remoteFeedCurrentDirectories = Set(TerminalOSC7SequenceParser.currentDirectories(from: candidateOSC7Bytes))
        isFeedingRemoteOutput = true
        defer {
            isFeedingRemoteOutput = false
            remoteFeedCurrentDirectories.removeAll(keepingCapacity: true)
        }
        terminalView.feedRemoteOutput(
            visibleBytes,
            applySemanticHighlighting: applySemanticHighlighting
        )
        resetRemoteInputLineAnchor()
        let wasCollectingOSC7Sequence = osc7OutputBuffer.isEmpty == false
        var didFinishCommand = recordOSC7DirectoryFromOutput(visibleBytes)
        if wasCollectingOSC7Sequence == false,
           osc7OutputBuffer.isEmpty,
           Self.containsOSC7Start(in: visibleBytes) == false
        {
            didFinishCommand = recordRemotePromptDirectoryFromOutput(visibleBytes) || didFinishCommand
        }
        TerminalOutputBroadcastHub.shared.publishOutput(runtimeID: runtimeID, bytes: visibleBytes)
        if didFinishCommand {
            TerminalOutputBroadcastHub.shared.publishCommandFinished(runtimeID: runtimeID)
        }
        terminalSearchController.terminalContentDidChange()
        if filteredOutput.didRemoveEcho {
            finishSilentInputEchoRecovery(restoreTerminalEcho: false)
        }
    }

    public func performDropLocalFilesForTesting(_ localPaths: [String]) {
        handleDroppedLocalFilePaths(localPaths)
    }

    private func displayStartupBannerIfNeeded() {
        guard didDisplayStartupBanner == false,
              let startupBanner,
              startupBanner.isEmpty == false
        else { return }

        didDisplayStartupBanner = true
    }

    @discardableResult
    public func pollRemoteOutputOnce() -> Bool {
        guard didClose == false,
              lifecycleState == .running
        else {
            return false
        }
        guard isPollingRemoteOutput == false else {
            return false
        }
        isPollingRemoteOutput = true
        defer {
            isPollingRemoteOutput = false
        }

        do {
            let polledRuntimeID = runtimeID
            let status = try bridge.pollLiveSSHShell(runtimeID: polledRuntimeID)
            guard status.runtimeId == polledRuntimeID else { return false }
            let batch = try bridge.takeTerminalOutputBatch(runtimeID: polledRuntimeID)
            guard batch.runtimeId == polledRuntimeID else { return false }
            updateOutputProtectionStatus(
                protectionActive: batch.protectionActive,
                droppedByteCount: batch.droppedByteCount,
                bufferedByteCount: batch.bufferedByteCount
            )
            var didReceiveOutput = false
            if !batch.bytes.isEmpty {
                feedRemoteOutput(
                    Array(batch.bytes),
                    applySemanticHighlighting: batch.protectionActive == false
                )
                didReceiveOutput = true
            }
            if status.status != "running" {
                stopOutputPolling()
                displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(status.diagnostic))
            }
            return didReceiveOutput
        } catch {
            guard Self.isTransientPollError(error) == false else {
                return false
            }
            stopOutputPolling()
            displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
            return false
        }
    }

    private func scheduleImmediateRemoteOutputDrain(
        followUpBursts: Int = RemoteTerminalPaneViewController.immediateOutputDrainFollowUpLimit
    ) {
        guard outputPollTimer != nil,
              didClose == false,
              lifecycleState == .running
        else { return }
        immediateOutputDrainFollowUpBurstsRemaining = max(
            immediateOutputDrainFollowUpBurstsRemaining,
            followUpBursts
        )
        guard immediateOutputDrainScheduled == false else { return }
        immediateOutputDrainScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.performImmediateRemoteOutputDrain()
        }
    }

    private func scheduleImmediateRemoteOutputDrainFollowUp() {
        guard immediateOutputDrainFollowUpBurstsRemaining > 0,
              outputPollTimer != nil,
              didClose == false,
              lifecycleState == .running
        else { return }
        guard immediateOutputDrainScheduled == false else { return }
        immediateOutputDrainScheduled = true
        immediateOutputDrainFollowUpBurstsRemaining -= 1
        let workItem = DispatchWorkItem { [weak self] in
            self?.performImmediateRemoteOutputDrain()
        }
        immediateOutputDrainFollowUpWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.immediateOutputDrainFollowUpDelay,
            execute: workItem
        )
    }

    private func performImmediateRemoteOutputDrain() {
        immediateOutputDrainFollowUpWorkItem = nil
        guard outputPollTimer != nil,
              didClose == false,
              lifecycleState == .running
        else {
            immediateOutputDrainScheduled = false
            return
        }
        pollRemoteOutputInBackground(
            maximumPasses: Self.immediateOutputDrainPassLimit
        ) { [weak self] _ in
            guard let self else { return }
            self.immediateOutputDrainScheduled = false
            self.immediateOutputDrainFollowUpWorkItem = nil
            guard self.outputPollTimer != nil,
                  self.didClose == false,
                  self.lifecycleState == .running
            else {
                return
            }
            self.scheduleImmediateRemoteOutputDrainFollowUp()
        }
    }

    public func closeTerminal() {
        guard didClose == false else { return }
        didClose = true
        reconnectGeneration &+= 1
        cancelAutomaticReconnect()
        (reconnecter as? RemoteTerminalBackgroundReconnecting)?.cancelPendingReconnects()
        resetSilentInputEchoRecoveryState()
        setLifecycle(.closed, message: L10n.TerminalLifecycle.disconnected)
        stopOutputPolling()
        _ = try? bridge.closeLiveSSHShell(runtimeID: runtimeID)
        try? eventSink.terminalDidClose(runtimeID: runtimeID)
    }

    public func sendInput(_ bytes: [UInt8]) {
        sendInput(bytes, broadcastUserInput: true)
    }

    public func sendAgentInput(_ bytes: [UInt8]) {
        sendInput(bytes, broadcastUserInput: false)
    }

    private func sendInput(_ bytes: [UInt8], broadcastUserInput: Bool) {
        if agentInteractionLocked && broadcastUserInput { return }
        guard lifecycleState == .running else {
            handleStoppedSessionInput(bytes)
            return
        }
        expireSilentInputEchoFiltersIfNeeded()
        sendInputImmediately(bytes, broadcastUserInput: broadcastUserInput)
    }

    public func setAgentInteractionLocked(_ locked: Bool) {
        agentInteractionLocked = locked
        agentInteractionGlow.setActive(locked)
    }

    public func refreshAgentTerminalOutput() {
        guard agentInteractionLocked else { return }
        pollRemoteOutputInBackground(allowWhenAgentInteractionLocked: true)
    }

    public var agentInteractionGlowActiveForTesting: Bool {
        agentInteractionGlow.isActiveForTesting
    }

    public var agentInteractionGlowPreservesTransparentCenterForTesting: Bool {
        agentInteractionGlow.preservesTransparentCenterForTesting
    }

    private func sendInputImmediately(_ bytes: [UInt8], broadcastUserInput: Bool) {
        let observation = commandInputObserver.ingest(
            bytes: bytes,
            settings: settingsStore.snapshot(),
            historyCommands: commandSuggestionHistoryCommands,
            pathCompletionProvider: pathCompletionProviderForCurrentInput()
        )
        remoteCompletionInputLine = observation.currentLine
        renderCommandInputObservation(observation)
        if observation.shouldConsumeInput && observation.acceptedCompletionBytes == nil {
            return
        }
        let outgoingBytes = observation.acceptedCompletionBytes ?? bytes
        do {
            if broadcastUserInput {
                TerminalOutputBroadcastHub.shared.publishUserInput(runtimeID: runtimeID, bytes: outgoingBytes)
            }
            try eventSink.terminalDidReceiveInput(runtimeID: runtimeID, bytes: outgoingBytes)
            recordSubmittedCommands(outgoingBytes)
            recordRemoteInputForDirectoryTracking(outgoingBytes)
            scheduleImmediateRemoteOutputDrain()
        } catch {
            stopOutputPolling()
            displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
        }
    }

    private func writePostConnectScriptIfNeeded() {
        guard connectionKind == .ssh,
              didWritePostConnectScript == false,
              lifecycleState == .running,
              runtimeID.hasPrefix("pending_") == false,
              let bytes = automationPolicy.postConnectInputBytes
        else {
            return
        }
        didWritePostConnectScript = true
        installSilentInputEchoFilter(for: bytes)
        beginSilentInputEchoRecoveryTimeout()
        do {
            try eventSink.terminalDidReceiveInput(runtimeID: runtimeID, bytes: bytes)
            scheduleImmediateRemoteOutputDrain()
        } catch {
            stopOutputPolling()
            displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
        }
    }

    private func installSilentInputEchoFilter(for bytes: [UInt8]) {
        let trimmed = Self.trimLineEnding(from: bytes)
        guard trimmed.isEmpty == false else {
            return
        }
        let echoed = trimmed.flatMap { byte -> [UInt8] in
            byte == UInt8(ascii: "\n") ? [UInt8(ascii: "\r"), UInt8(ascii: "\n")] : [byte]
        }
        var echoedWithLineEnding = echoed
        echoedWithLineEnding.append(UInt8(ascii: "\r"))
        echoedWithLineEnding.append(UInt8(ascii: "\n"))
        let patterns = Self.uniqueEchoFilterPatterns([echoedWithLineEnding, echoed])
        guard patterns.isEmpty == false else {
            return
        }
        pendingSilentInputEchoFilters.append(
            PendingSilentInputEchoFilter(
                patterns: patterns,
                expiresAt: Date().addingTimeInterval(silentInputEchoTimeout)
            )
        )
    }

    private func filterPendingSilentInputEcho(from bytes: [UInt8]) -> SilentInputEchoFilterResult {
        expireSilentInputEchoFiltersIfNeeded()
        guard pendingSilentInputEchoFilters.isEmpty == false else {
            return SilentInputEchoFilterResult(bytes: bytes, didRemoveEcho: false)
        }
        let now = Date()
        var visibleBytes = bytes
        var didRemoveAnyEcho = false
        var retainedFilters: [PendingSilentInputEchoFilter] = []
        for filter in pendingSilentInputEchoFilters {
            guard filter.expiresAt > now else {
                continue
            }
            var didRemoveEcho = false
            for pattern in filter.patterns {
                let result = Self.removeConfirmedEchoOccurrence(of: pattern, from: visibleBytes)
                if result.didRemove {
                    visibleBytes = result.bytes
                    didRemoveEcho = true
                    didRemoveAnyEcho = true
                    break
                }
            }
            if didRemoveEcho {
                continue
            }
            retainedFilters.append(filter)
        }
        pendingSilentInputEchoFilters = retainedFilters
        return SilentInputEchoFilterResult(bytes: visibleBytes, didRemoveEcho: didRemoveAnyEcho)
    }

    private func beginSilentInputEchoRecoveryTimeout() {
        silentInputEchoRecoveryTimeoutWorkItem?.cancel()
        let deadline = Date().addingTimeInterval(silentInputEchoTimeout)
        silentInputEchoRecoveryDeadline = deadline
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleSilentInputEchoRecoveryTimeout()
        }
        silentInputEchoRecoveryTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + silentInputEchoTimeout, execute: workItem)
    }

    private func handleSilentInputEchoRecoveryTimeout() {
        guard silentInputEchoRecoveryDeadline != nil else {
            return
        }
        finishSilentInputEchoRecovery(restoreTerminalEcho: true)
    }

    private func finishSilentInputEchoRecovery(restoreTerminalEcho: Bool) {
        guard silentInputEchoRecoveryDeadline != nil || pendingSilentInputEchoFilters.isEmpty == false else {
            return
        }
        silentInputEchoRecoveryDeadline = nil
        silentInputEchoRecoveryTimeoutWorkItem?.cancel()
        silentInputEchoRecoveryTimeoutWorkItem = nil
        pendingSilentInputEchoFilters.removeAll(keepingCapacity: true)
        if restoreTerminalEcho {
            sendTerminalEchoRestoreInput()
        }
    }

    private func sendTerminalEchoRestoreInput() {
        installSilentInputEchoFilter(for: Self.terminalEchoRestoreInput)
        do {
            try eventSink.terminalDidReceiveInput(runtimeID: runtimeID, bytes: Self.terminalEchoRestoreInput)
            scheduleImmediateRemoteOutputDrain()
        } catch {
            // The timeout path is best-effort; normal polling will surface runtime failures.
        }
    }

    private func expireSilentInputEchoFiltersIfNeeded() {
        guard pendingSilentInputEchoFilters.isEmpty == false else {
            return
        }
        let now = Date()
        pendingSilentInputEchoFilters.removeAll { filter in
            filter.expiresAt <= now
        }
    }

    private func resetSilentInputEchoRecoveryState() {
        silentInputEchoRecoveryTimeoutWorkItem?.cancel()
        silentInputEchoRecoveryTimeoutWorkItem = nil
        silentInputEchoRecoveryDeadline = nil
        pendingSilentInputEchoFilters.removeAll(keepingCapacity: true)
    }

    private func resetTerminalOutputForConnectedRuntime() {
        transcriptRecorder.reset()
        terminalView.getTerminal().resetToInitialState()
        terminalView.needsDisplay = true
        terminalSearchController.terminalContentDidChange()
        osc7OutputBuffer.removeAll(keepingCapacity: true)
        remotePromptOutputBuffer.removeAll(keepingCapacity: true)
        remoteFeedCurrentDirectories.removeAll(keepingCapacity: true)
        resetRemoteInputLineAnchor()
    }

    public func displayConnectionStarting() {
        cancelAutomaticReconnect()
        initialTransientNetworkFailureCount = 0
        if connectionKind == .ssh,
           hasEstablishedRuntime == false
        {
            resetTerminalOutputForConnectedRuntime()
        }
        setLifecycle(.connecting, message: L10n.TerminalLifecycle.connecting)
    }

    public func displayConnectionFailure(_ diagnostic: String) {
        guard didClose == false,
              lifecycleState != .closed
        else {
            return
        }

        let message = RuntimeDiagnosticFormatter.userMessage(diagnostic)
        resetSilentInputEchoRecoveryState()
        let isInitialSSHConnectionFailure = connectionKind == .ssh && hasEstablishedRuntime == false
        if isInitialSSHConnectionFailure {
            resetTerminalOutputForConnectedRuntime()
            if shouldRetryInitialSSHNetworkFailure(diagnostic) {
                setLifecycle(.connecting, message: L10n.TerminalLifecycle.connecting)
                if scheduleAutomaticReconnectIfNeeded() {
                    initialTransientNetworkFailureCount += 1
                    return
                }
            }
            setLifecycle(.disconnected, message: L10n.TerminalLifecycle.connectionFailedMessage(message))
            return
        } else {
            feedRemoteOutput(Array(
                L10n.TerminalLifecycle.stoppedSessionPrompt(
                    diagnostic: message,
                    connectionKind: connectionKind
                ).utf8
            ))
        }
        setLifecycle(.disconnected, message: L10n.TerminalLifecycle.disconnectedMessage(message))
        scheduleAutomaticReconnectIfNeeded()
    }

    public func attachConnectedRuntime(
        status: LiveShellStatus,
        liveSessionContext: TunnelLiveSessionContext? = nil,
        automationPolicy: SessionAutomationPolicy? = nil,
        startupBanner: String? = nil
    ) {
        guard didClose == false,
              lifecycleState != .closed
        else {
            _ = try? bridge.closeLiveSSHShell(runtimeID: status.runtimeId)
            return
        }

        guard status.status == "running" else {
            _ = try? bridge.closeLiveSSHShell(runtimeID: status.runtimeId)
            displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(status.diagnostic))
            return
        }

        resetSilentInputEchoRecoveryState()
        resetTerminalOutputForConnectedRuntime()
        runtimeID = status.runtimeId
        hasEstablishedRuntime = true
        initialTransientNetworkFailureCount = 0
        didWritePostConnectScript = false
        if let liveSessionContext {
            self.liveSessionContext = liveSessionContext
        }
        if let automationPolicy {
            self.automationPolicy = automationPolicy
        }
        if let startupBanner, startupBanner.isEmpty == false {
            didDisplayStartupBanner = true
        }
        cancelAutomaticReconnect()
        setLifecycle(.running, message: "")
        onMultiExecPresentationChanged?(self)
        if isViewLoaded {
            startOutputPollingIfNeeded()
            focusTerminalViewForKeyboardInput()
        }
        writePostConnectScriptIfNeeded()
        onRuntimeAttached?(self, status, liveSessionContext)
    }

    func discardUnattachedRuntime(_ status: LiveShellStatus) {
        _ = try? bridge.closeLiveSSHShell(runtimeID: status.runtimeId)
    }

    @discardableResult
    public func reconnectTerminal() throws -> LiveShellStatus {
        try reconnectTerminal(trigger: .manual)
    }

    private enum ReconnectTrigger {
        case manual
        case automatic
    }

    @discardableResult
    private func reconnectTerminal(trigger: ReconnectTrigger) throws -> LiveShellStatus {
        guard let reconnecter else {
            throw RemoteTerminalLifecycleError.reconnectUnavailable
        }

        if trigger == .manual {
            cancelAutomaticReconnect()
        }
        let oldRuntimeID = runtimeID
        setLifecycle(.reconnecting, message: L10n.TerminalLifecycle.reconnecting)
        stopOutputPolling()
        resetSilentInputEchoRecoveryState()
        reconnectGeneration &+= 1
        let generation = reconnectGeneration

        if let backgroundReconnecter = reconnecter as? RemoteTerminalBackgroundReconnecting {
            let bridge = bridge
            let title = terminalTitle
            let automatically = trigger == .automatic
            DispatchQueue.global(qos: .utility).async { [weak self, weak backgroundReconnecter] in
                _ = try? bridge.closeLiveSSHShell(runtimeID: oldRuntimeID)
                DispatchQueue.main.async {
                    guard let self,
                          let backgroundReconnecter,
                          self.didClose == false,
                          self.reconnectGeneration == generation
                    else { return }
                    backgroundReconnecter.reconnectRemoteTerminalInBackground(
                        title: title,
                        automatically: automatically
                    ) { [weak self] result in
                        guard let self,
                              self.didClose == false,
                              self.reconnectGeneration == generation
                        else {
                            if case let .success(status) = result {
                                _ = try? bridge.closeLiveSSHShell(runtimeID: status.runtimeId)
                            }
                            return
                        }
                        do {
                            let status = try result.get()
                            try self.finishReconnect(status: status, oldRuntimeID: oldRuntimeID)
                        } catch {
                            self.displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
                        }
                    }
                }
            }
            return LiveShellStatus(
                runtimeId: oldRuntimeID,
                status: "connecting",
                diagnostic: L10n.TerminalLifecycle.reconnecting
            )
        }

        _ = try? bridge.closeLiveSSHShell(runtimeID: oldRuntimeID)
        do {
            let status = try trigger == .manual
                ? reconnecter.reconnectRemoteTerminal(title: terminalTitle)
                : reconnecter.reconnectRemoteTerminalAutomatically(title: terminalTitle)
            try finishReconnect(status: status, oldRuntimeID: oldRuntimeID)
            return status
        } catch {
            displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
            throw error
        }
    }

    private func finishReconnect(status: LiveShellStatus, oldRuntimeID: String) throws {
        guard status.status == "running" else {
            _ = try? bridge.closeLiveSSHShell(runtimeID: status.runtimeId)
            let message = RuntimeDiagnosticFormatter.userMessage(status.diagnostic)
            throw RemoteTerminalLifecycleError.reconnectFailed(message: message)
        }
        resetSilentInputEchoRecoveryState()
        resetTerminalOutputForConnectedRuntime()
        runtimeID = status.runtimeId
        hasEstablishedRuntime = true
        didWritePostConnectScript = false
        if let refreshedContext = reconnecter?.liveSessionContext {
            liveSessionContext = refreshedContext
        }
        setLifecycle(.running, message: "")
        onMultiExecPresentationChanged?(self)
        if startsPollingAutomatically, view.window != nil {
            startOutputPollingIfNeeded()
        }
        writePostConnectScriptIfNeeded()
        let attachedContext = reconnecter?.liveSessionContext ?? liveSessionContext
        onRuntimeAttached?(self, status, attachedContext)
        onRuntimeReattached?(self, oldRuntimeID, status, attachedContext)
    }

    @discardableResult
    public func find(_ term: String) -> Bool {
        terminalView.findNext(term)
    }

    public func copySelection() {
        terminalView.copy(self)
    }

    public func pasteClipboard() {
        _ = TerminalPastePreparation.pastePreparedString(
            into: terminalView,
            settings: settingsStore.snapshot()
        )
    }

    public func terminalContextMenuForTesting(selectedText: String?) -> NSMenu {
        terminalContextMenuController.makeMenu(selectedText: selectedText)
    }

    public func showFind() {
        terminalSearchController.show()
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard TerminalResizeValidator.shouldForward(cols: newCols, rows: newRows) else { return }
        enqueueTerminalResize(runtimeID: runtimeID, cols: newCols, rows: newRows)
        refreshLineInfoGutter()
    }

    private func enqueueTerminalResize(runtimeID: String, cols: Int, rows: Int) {
        pendingTerminalResize = (runtimeID, cols, rows)
        sendPendingTerminalResizeIfNeeded()
    }

    private func sendPendingTerminalResizeIfNeeded() {
        guard isSendingTerminalResize == false, let resize = pendingTerminalResize else { return }
        pendingTerminalResize = nil
        isSendingTerminalResize = true
        let eventSink = eventSink
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? eventSink.terminalDidResize(
                runtimeID: resize.runtimeID,
                cols: resize.cols,
                rows: resize.rows
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSendingTerminalResize = false
                self.sendPendingTerminalResizeIfNeeded()
            }
        }
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let normalized = TerminalCurrentDirectoryNormalizer.normalize(directory) else {
            return
        }
        guard isFeedingRemoteOutput == false || remoteFeedCurrentDirectories.contains(normalized) else {
            return
        }
        updateCurrentRemoteDirectory(normalized)
    }

    private func handleDroppedLocalFilePaths(_ localPaths: [String]) {
        guard localPaths.isEmpty == false,
              canAcceptDroppedLocalFiles
        else { return }
        onUploadDroppedFiles?(currentRemoteDirectory, localPaths)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        if onUserInput?(self, bytes) == true {
            return
        }
        sendInput(bytes, broadcastUserInput: true)
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func clipboardCopy(source: TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([string as NSString])
        }
    }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = TerminalLinkURLNormalizer.browserURL(from: link) {
            linkOpener.openTerminalLink(url)
        } else if let path = TerminalLinkURLNormalizer.terminalPath(from: link) {
            copyTerminalPathToPasteboard(path)
        }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        refreshLineInfoGutter()
    }

    public var lifecycleMessageForTesting: String {
        lifecycleLabel.stringValue
    }

    public var isLifecycleBarVisibleForTesting: Bool {
        lifecycleBar.isHidden == false
    }

    public var didDisplayStartupBannerForTesting: Bool {
        didDisplayStartupBanner
    }

    public var terminalSearchBarVisibleForTesting: Bool {
        terminalSearchController.isVisible
    }

    public var terminalSearchSummaryForTesting: String {
        terminalSearchController.summaryText
    }

    public var terminalSearchVisibleHighlightCountForTesting: Int {
        terminalSearchController.visibleHighlightCount
    }

    public func setTerminalSearchQueryForTesting(_ query: String) {
        terminalSearchController.setQuery(query)
    }

    public func selectNextTerminalSearchMatchForTesting() {
        terminalSearchController.selectNext()
    }

    public func selectPreviousTerminalSearchMatchForTesting() {
        terminalSearchController.selectPrevious()
    }

    public func closeTerminalSearchWithEscapeForTesting() {
        terminalSearchController.close()
    }

    private func copyTerminalPathToPasteboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    public var terminalOutputTranscript: String {
        transcriptRecorder.snapshot
    }

    public var outputProtectionStatusVisibleForTesting: Bool {
        outputProtectionBar.isHidden == false
    }

    public var outputProtectionStatusTextForTesting: String {
        outputProtectionLabel.stringValue
    }

    public var terminalDisplaySnapshotForTesting: String {
        String(data: terminalView.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
    }

    public var terminalLastFeedAppliedSemanticHighlightingForTesting: Bool {
        terminalView.lastFeedAppliedSemanticHighlightingForTesting
    }

    public func toggleOutputPauseForTesting() {
        toggleOutputPause()
    }

    public func appendAgentTrace(
        requestID: String,
        state: AgentTraceState,
        message: String,
        redactedCommand: String?,
        metadata: [String: String]? = nil
    ) {
        let event = AgentTraceEvent(
            requestID: requestID,
            state: state,
            message: message,
            redactedCommand: redactedCommand,
            metadata: metadata
        )
        agentTraceController.append(
            TerminalTraceEvent(
                requestID: event.requestID,
                state: event.state,
                message: event.message,
                redactedCommand: event.redactedCommand,
                metadata: event.metadata
            )
        )
        agentTraceOverlay.render(agentTraceController.eventsSnapshot)
        TerminalAgentTraceNotification.post(
            runtimeID: runtimeID,
            title: terminalTitle,
            event: event
        )
    }

    public var agentTraceSnapshotForTesting: String {
        agentTraceController.snapshot
    }

    public var agentTraceOverlayTextForTesting: String {
        agentTraceOverlay.visibleTextForTesting
    }

    public var agentTraceOverlayVisibleForTesting: Bool {
        agentTraceOverlay.isHidden == false
    }

    public var commandHintVisibleTextForTesting: String {
        commandHintOverlay.visibleTextForTesting
    }

    public var commandHintCompletionChoiceCountForTesting: Int {
        commandHintOverlay.completionChoiceCountForTesting
    }

    public var commandHintSelectedCompletionIndexForTesting: Int {
        commandHintOverlay.selectedCompletionIndexForTesting
    }

    public var commandHintPresentationKindForTesting: TerminalCommandHintOverlayPresentationKind {
        commandHintOverlay.presentationKind
    }

    public var commandHintUsesTerminalCompletionStyleForTesting: Bool {
        commandHintOverlay.usesTerminalCompletionStyleForTesting
    }

    public var commandHintCompletionUsesFixedDarkAppearanceForTesting: Bool {
        commandHintOverlay.completionUsesFixedDarkAppearanceForTesting
    }

    public var commandHintCompletionBackgroundColorForTesting: NSColor {
        commandHintOverlay.completionBackgroundColorForTesting
    }

    public var commandHintCompletionPrimaryTextColorForTesting: NSColor {
        commandHintOverlay.completionPrimaryTextColorForTesting
    }

    public var commandHintFrameForTesting: NSRect {
        commandHintOverlay.frame
    }

    public var lineInfoGutterVisibleTextForTesting: String {
        lineInfoGutter.visibleTextForTesting
    }

    public var lineInfoGutterPreferredWidthForTesting: CGFloat {
        lineInfoGutter.preferredWidthForTesting
    }

    public var lineInfoGutterUsesTerminalSurfaceStyleForTesting: Bool {
        lineInfoGutter.usesTerminalSurfaceStyleForTesting
    }

    public var lineInfoGutterFontPointSizeForTesting: CGFloat {
        lineInfoGutter.lineInfoFontPointSizeForTesting
    }

    public var lineInfoGutterLabelCountForTesting: Int {
        lineInfoGutter.lineInfoLabelCountForTesting
    }

    public var lineInfoGutterRowHeightForTesting: CGFloat {
        lineInfoGutter.lineInfoRowHeightForTesting
    }

    public func appendAgentTraceForTesting(
        requestID: String,
        state: AgentTraceState,
        message: String,
        redactedCommand: String?,
        metadata: [String: String]? = nil
    ) {
        appendAgentTrace(
            requestID: requestID,
            state: state,
            message: message,
            redactedCommand: redactedCommand,
            metadata: metadata
        )
    }

    public var isMultiExecPausedForTesting: Bool {
        isMultiExecPaused
    }

    public func setMultiExecModeEnabled(_ enabled: Bool, paused: Bool = false) {
        multiExecModeEnabled = enabled
        setMultiExecPaused(paused, notify: false)
    }

    public func setMultiExecPaused(_ paused: Bool, notify: Bool = true) {
        isMultiExecPaused = paused
        onMultiExecPresentationChanged?(self)
        if notify {
            onMultiExecPauseChanged?(self, paused)
        }
    }

    public func makeMultiExecPauseButton() -> NSButton {
        let button = NSButton(image: multiExecPauseButtonImage(), target: self, action: #selector(multiExecPauseButtonPressed))
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.toolTip = multiExecPauseButtonToolTip
        button.setAccessibilityIdentifier("Stacio.Terminal.multiExecPause.\(runtimeID)")
        button.setAccessibilityLabel(multiExecPauseButtonToolTip)
        return button
    }

    deinit {
        outputPollTimer?.invalidate()
        automaticReconnectWorkItem?.cancel()
        silentInputEchoRecoveryTimeoutWorkItem?.cancel()
        cancelImmediateOutputDrain()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func configureLifecycleBar() {
        lifecycleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reconnectButton.bezelStyle = .rounded
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectButtonPressed)
        lifecycleBar.orientation = .horizontal
        lifecycleBar.spacing = 8
        lifecycleBar.alignment = .centerY
        lifecycleBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        lifecycleBar.wantsLayer = true
        lifecycleBar.layer?.cornerRadius = 6
        lifecycleBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        lifecycleBar.translatesAutoresizingMaskIntoConstraints = false
        lifecycleBar.addArrangedSubview(lifecycleLabel)
        lifecycleBar.addArrangedSubview(reconnectButton)
        applyLifecyclePresentation()
    }

    private func configureOutputProtectionBar() {
        outputProtectionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        outputProtectionLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        outputProtectionLabel.lineBreakMode = .byTruncatingTail
        outputProtectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        outputProtectionToggleButton.bezelStyle = .rounded
        outputProtectionToggleButton.controlSize = .small
        outputProtectionToggleButton.target = self
        outputProtectionToggleButton.action = #selector(outputProtectionToggleButtonPressed)
        outputProtectionToggleButton.setAccessibilityIdentifier("Stacio.Terminal.outputProtection.toggle.\(runtimeID)")

        outputProtectionBar.orientation = .horizontal
        outputProtectionBar.spacing = 8
        outputProtectionBar.alignment = .centerY
        outputProtectionBar.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        outputProtectionBar.wantsLayer = true
        outputProtectionBar.layer?.cornerRadius = 6
        outputProtectionBar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        outputProtectionBar.translatesAutoresizingMaskIntoConstraints = false
        outputProtectionBar.setAccessibilityIdentifier("Stacio.Terminal.outputProtection")
        outputProtectionBar.addArrangedSubview(outputProtectionLabel)
        outputProtectionBar.addArrangedSubview(outputProtectionToggleButton)
        outputProtectionBar.isHidden = true
        updateOutputProtectionBar()
    }

    private func updateOutputProtectionStatus(
        protectionActive: Bool,
        droppedByteCount: UInt32,
        bufferedByteCount: UInt32
    ) {
        outputProtectionActive = protectionActive
        outputProtectionDroppedByteCount = droppedByteCount
        outputProtectionBufferedByteCount = bufferedByteCount
        updateOutputProtectionBar()
    }

    private func updateOutputProtectionBar() {
        outputProtectionToggleButton.title = isOutputPaused
            ? L10n.TerminalOutputProtection.resume
            : L10n.TerminalOutputProtection.pause
        outputProtectionToggleButton.setAccessibilityLabel(outputProtectionToggleButton.title)

        var segments: [String] = []
        if isOutputPaused {
            segments.append(L10n.TerminalOutputProtection.paused)
        } else if outputProtectionActive {
            segments.append(L10n.TerminalOutputProtection.protected)
        }
        if outputProtectionBufferedByteCount > 0 {
            segments.append(L10n.TerminalOutputProtection.bufferedBytes(outputProtectionBufferedByteCount))
        }
        if outputProtectionDroppedByteCount > 0 {
            segments.append(L10n.TerminalOutputProtection.droppedBytes(outputProtectionDroppedByteCount))
        }

        outputProtectionLabel.stringValue = segments.joined(separator: " · ")
        outputProtectionBar.isHidden = segments.isEmpty
    }

    @objc
    private func outputProtectionToggleButtonPressed(_ sender: Any?) {
        toggleOutputPause()
    }

    private func toggleOutputPause() {
        do {
            let runtime = try bridge.setTerminalOutputPaused(
                runtimeID: runtimeID,
                paused: isOutputPaused == false
            )
            isOutputPaused = runtime.outputPaused
            if isOutputPaused == false {
                scheduleImmediateRemoteOutputDrain()
            }
            updateOutputProtectionBar()
        } catch {
            displayConnectionFailure(RuntimeDiagnosticFormatter.userMessage(for: error))
        }
    }

    private var multiExecPauseButtonToolTip: String {
        isMultiExecPaused ? L10n.MultiExec.resumeTerminal : L10n.MultiExec.pauseTerminal
    }

    private func multiExecPauseButtonImage() -> NSImage {
        NSImage(
            systemSymbolName: isMultiExecPaused ? "play.circle" : "pause.circle",
            accessibilityDescription: multiExecPauseButtonToolTip
        )
        ?? NSImage()
    }

    private func handleStoppedSessionInput(_ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if text == "r" {
            reconnectFromStoppedPrompt()
            return
        }
        if text == "s" {
            onRequestSaveOutput?(self)
            return
        }
        if isReturnKey(bytes) {
            if connectionKind == .serial {
                reconnectFromStoppedPrompt()
            } else if let onRequestClose {
                onRequestClose(self)
            } else {
                closeTerminal()
            }
        }
    }

    private func recordRemoteInputForDirectoryTracking(_ bytes: [UInt8]) {
        for byte in bytes {
            switch byte {
            case 10, 13:
                processRemoteInputLineForDirectoryTracking()
            case 3, 21, 27:
                remoteInputLineBuffer.removeAll()
                remoteInputLineUsedCompletion = false
            case 9:
                remoteInputLineUsedCompletion = true
            case 8, 127:
                removeLastRemoteInputCharacter()
            case 0..<32:
                continue
            default:
                remoteInputLineBuffer.append(byte)
            }
        }
    }

    private func removeLastRemoteInputCharacter() {
        guard remoteInputLineBuffer.isEmpty == false else {
            return
        }
        let text = String(decoding: remoteInputLineBuffer, as: UTF8.self)
        remoteInputLineBuffer = Array(text.dropLast().utf8)
    }

    private func processRemoteInputLineForDirectoryTracking() {
        guard remoteInputLineBuffer.isEmpty == false else {
            remoteInputLineUsedCompletion = false
            return
        }
        let line = String(decoding: remoteInputLineBuffer, as: UTF8.self)
        remoteInputLineBuffer.removeAll()
        guard remoteInputLineUsedCompletion == false else {
            remoteInputLineUsedCompletion = false
            return
        }
        remoteInputLineUsedCompletion = false
        for command in RemoteDirectoryCommandParser.directoryCommands(from: line) {
            guard let updatedDirectory = resolvedRemoteDirectory(for: command) else {
                continue
            }
            updateCurrentRemoteDirectory(updatedDirectory)
        }
    }

    @discardableResult
    private func recordOSC7DirectoryFromOutput(_ bytes: [UInt8]) -> Bool {
        guard bytes.isEmpty == false else {
            return false
        }
        osc7OutputBuffer.append(contentsOf: bytes)
        if osc7OutputBuffer.count > 4_096 {
            osc7OutputBuffer = Array(osc7OutputBuffer.suffix(4_096))
        }
        var didRecordDirectory = false
        for directory in TerminalOSC7SequenceParser.currentDirectories(from: osc7OutputBuffer) {
            commandCompletionGeneration &+= 1
            onCommandFinished?(self)
            updateCurrentRemoteDirectory(directory)
            didRecordDirectory = true
        }
        trimOSC7OutputBuffer()
        return didRecordDirectory
    }

    private func trimOSC7OutputBuffer() {
        guard let lastEscape = osc7OutputBuffer.lastIndex(of: 0x1B) else {
            osc7OutputBuffer.removeAll(keepingCapacity: true)
            return
        }
        let suffix = Array(osc7OutputBuffer[lastEscape...])
        if suffix.count >= 4,
           suffix[1] == 0x5D,
           suffix[2] == 0x37,
           suffix[3] == 0x3B,
           TerminalOSC7SequenceParser.currentDirectories(from: suffix).isEmpty
        {
            osc7OutputBuffer = suffix
        } else {
            osc7OutputBuffer.removeAll(keepingCapacity: true)
        }
    }

    private static func containsOSC7Start(in bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else {
            return false
        }
        for index in 0...(bytes.count - 4) where
            bytes[index] == 0x1B &&
            bytes[index + 1] == 0x5D &&
            bytes[index + 2] == 0x37 &&
            bytes[index + 3] == 0x3B
        {
            return true
        }
        return false
    }

    private static func trimLineEnding(from bytes: [UInt8]) -> [UInt8] {
        if bytes.count >= 2,
           bytes[bytes.count - 2] == UInt8(ascii: "\r"),
           bytes[bytes.count - 1] == UInt8(ascii: "\n")
        {
            return Array(bytes.dropLast(2))
        }
        if let last = bytes.last,
           last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            return Array(bytes.dropLast())
        }
        return bytes
    }

    private static func uniqueEchoFilterPatterns(_ patterns: [[UInt8]]) -> [[UInt8]] {
        var uniquePatterns: [[UInt8]] = []
        for pattern in patterns where pattern.isEmpty == false {
            if uniquePatterns.contains(pattern) == false {
                uniquePatterns.append(pattern)
            }
        }
        return uniquePatterns
    }

    private static func removeConfirmedEchoOccurrence(
        of needle: [UInt8],
        from haystack: [UInt8]
    ) -> (bytes: [UInt8], didRemove: Bool) {
        guard needle.isEmpty == false,
              haystack.count >= needle.count
        else {
            return (haystack, false)
        }
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            if Array(haystack[start..<end]) == needle,
               isConfirmedEchoRange(pattern: needle, in: haystack, start: start, end: end)
            {
                var filtered = Array(haystack[..<start])
                filtered.append(contentsOf: haystack[end...])
                return (filtered, true)
            }
        }
        return (haystack, false)
    }

    private static func isConfirmedEchoRange(
        pattern: [UInt8],
        in haystack: [UInt8],
        start: Int,
        end: Int
    ) -> Bool {
        hasEchoStartBoundary(in: haystack, start: start)
            && hasEchoEndBoundary(pattern: pattern, in: haystack, end: end)
    }

    private static func hasEchoStartBoundary(in bytes: [UInt8], start: Int) -> Bool {
        guard start > 0 else {
            return true
        }
        let previous = bytes[start - 1]
        if previous == UInt8(ascii: "\n") || previous == UInt8(ascii: "\r") {
            return true
        }
        guard previous == UInt8(ascii: " ") || previous == UInt8(ascii: "\t") else {
            return false
        }
        let lineStart = bytes[..<start].lastIndex { byte in
            byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        }.map { bytes.index(after: $0) } ?? bytes.startIndex
        let linePrefix = Array(bytes[lineStart..<start])
        return linePrefixLooksLikePrompt(linePrefix)
    }

    private static func hasEchoEndBoundary(pattern: [UInt8], in bytes: [UInt8], end: Int) -> Bool {
        if pattern.last == UInt8(ascii: "\n") || pattern.last == UInt8(ascii: "\r") {
            return true
        }
        guard end < bytes.count else {
            return true
        }
        let next = bytes[end]
        return next == UInt8(ascii: "\n") || next == UInt8(ascii: "\r")
    }

    private static func linePrefixLooksLikePrompt(_ bytes: [UInt8]) -> Bool {
        let text = strippedTerminalEscapes(from: String(decoding: bytes, as: UTF8.self))
            .trimmingCharacters(in: .whitespaces)
        guard text.isEmpty == false else {
            return false
        }
        if promptDirectory(fromLine: text) != nil {
            return true
        }
        guard let marker = text.last else {
            return false
        }
        return isSupportedPromptMarker(marker)
    }

    @discardableResult
    private func recordRemotePromptDirectoryFromOutput(_ bytes: [UInt8]) -> Bool {
        guard bytes.isEmpty == false else {
            return false
        }
        remotePromptOutputBuffer.append(String(decoding: bytes, as: UTF8.self))
        if remotePromptOutputBuffer.count > 4_096 {
            remotePromptOutputBuffer = String(remotePromptOutputBuffer.suffix(4_096))
        }
        guard let directory = Self.promptDirectory(fromTrailingOutput: remotePromptOutputBuffer),
              let normalized = TerminalCurrentDirectoryNormalizer.normalize(directory)
        else {
            return false
        }
        commandCompletionGeneration &+= 1
        onCommandFinished?(self)
        updateCurrentRemoteDirectory(normalized)
        return true
    }

    private static func promptDirectory(fromTrailingOutput output: String) -> String? {
        let cleanedOutput = strippedTerminalEscapes(from: output)
        let lastLine = cleanedOutput
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .last { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let lastLine else {
            return nil
        }
        return promptDirectory(fromLine: lastLine)
    }

    private static func promptDirectory(fromLine line: String) -> String? {
        guard let promptMarker = line.last,
              isSupportedPromptMarker(promptMarker)
        else {
            return nil
        }
        let body = line.dropLast().trimmingCharacters(in: .whitespaces)
        if let bracketedDirectory = bracketedPromptDirectory(fromBody: String(body)) {
            return bracketedDirectory
        }
        var bestDirectory: String?
        var searchStart = body.startIndex
        while searchStart < body.endIndex,
              let atIndex = body[searchStart...].firstIndex(of: "@")
        {
            defer { searchStart = body.index(after: atIndex) }
            guard let colonIndex = body[atIndex...].firstIndex(of: ":") else {
                continue
            }
            let promptStart = body[..<atIndex]
                .lastIndex(where: { $0.isWhitespace || $0 == "$" || $0 == "#" })
                .map { body.index(after: $0) } ?? body.startIndex
            let user = body[promptStart..<atIndex]
            let host = body[body.index(after: atIndex)..<colonIndex]
            guard isPromptUser(user),
                  isPromptHost(host)
            else {
                continue
            }
            let directory = body[body.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            guard directory == "~" || directory.hasPrefix("~/") || directory.hasPrefix("/") else {
                continue
            }
            bestDirectory = directory
        }
        return bestDirectory
    }

    private static func isSupportedPromptMarker(_ marker: Character) -> Bool {
        marker == "$" || marker == "#" || marker == "%" || marker == ">"
    }

    private static func bracketedPromptDirectory(fromBody body: String) -> String? {
        guard body.hasSuffix("]"),
              let openBracket = body.lastIndex(of: "[")
        else {
            return nil
        }
        let closeBracket = body.index(before: body.endIndex)
        let contents = body[body.index(after: openBracket)..<closeBracket]
        guard let atIndex = contents.firstIndex(of: "@"),
              let separatorIndex = contents[atIndex...].firstIndex(where: { $0.isWhitespace })
        else {
            return nil
        }
        let user = contents[..<atIndex]
        let host = contents[contents.index(after: atIndex)..<separatorIndex]
        guard isPromptUser(user),
              isPromptHost(host)
        else {
            return nil
        }
        let directory = contents[contents.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespaces)
        guard directory == "~" || directory.hasPrefix("~/") || directory.hasPrefix("/") else {
            return nil
        }
        return directory
    }

    private static func isPromptUser(_ value: Substring) -> Bool {
        isPromptIdentityComponent(value, disallowed: [":", "/", "@", "$", "#"])
    }

    private static func isPromptHost(_ value: Substring) -> Bool {
        isPromptIdentityComponent(value, disallowed: [":", "/", "@", "$", "#"])
    }

    private static func isPromptIdentityComponent(_ value: Substring, disallowed: Set<Character>) -> Bool {
        guard value.isEmpty == false else {
            return false
        }
        return value.allSatisfy { character in
            character.isWhitespace == false && disallowed.contains(character) == false
        }
    }

    private static func strippedTerminalEscapes(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 0x1B else {
                output.append(scalar)
                index += 1
                continue
            }

            index += 1
            guard index < scalars.count else {
                break
            }

            let introducer = scalars[index].value
            if introducer == 0x5B {
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if value >= 0x40 && value <= 0x7E {
                        break
                    }
                }
                continue
            }

            if introducer == 0x5D {
                index += 1
                while index < scalars.count {
                    let value = scalars[index].value
                    if value == 0x07 {
                        index += 1
                        break
                    }
                    if value == 0x1B,
                       index + 1 < scalars.count,
                       scalars[index + 1].value == 0x5C {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }

            index += 1
        }
        return String(output)
    }

    private func resolvedRemoteDirectory(
        for command: RemoteDirectoryCommandParser.DirectoryCommand
    ) -> String? {
        switch command {
        case .change(let target):
            return RemoteDirectoryCommandParser.resolvedDirectory(
                for: .change(target),
                currentDirectory: currentRemoteDirectory,
                previousDirectory: previousRemoteDirectory
            )
        case .previous:
            return previousRemoteDirectory
        case .push(let target):
            remoteDirectoryStack.insert(currentRemoteDirectory, at: 0)
            return RemoteDirectoryCommandParser.resolvedDirectory(
                for: .change(target),
                currentDirectory: currentRemoteDirectory,
                previousDirectory: previousRemoteDirectory
            )
        case .pop:
            guard remoteDirectoryStack.isEmpty == false else {
                return nil
            }
            return remoteDirectoryStack.removeFirst()
        }
    }

    private func updateCurrentRemoteDirectory(_ directory: String) {
        let previous = currentRemoteDirectory
        guard directory != previous else {
            return
        }
        currentRemoteDirectory = directory
        previousRemoteDirectory = previous
        if injectedPathCompletionProvider == nil,
           connectionKind == .ssh {
            liveRemotePathCompletionProvider.warm(parentPath: ".")
        }
        onRemoteDirectoryChanged?(self, directory)
    }

    private func reconnectFromStoppedPrompt() {
        do {
            _ = try reconnectTerminal()
        } catch {
        }
    }

    private func shouldRetryInitialSSHNetworkFailure(_ diagnostic: String) -> Bool {
        guard startsPollingAutomatically,
              reconnecter != nil,
              initialTransientNetworkFailureCount < 3
        else {
            return false
        }

        let normalized = diagnostic
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("无法到达主机")
            || normalized.contains("network is unreachable")
            || normalized.contains("no route to host")
            || normalized.contains("host is unreachable")
            || normalized.contains("os error 65")
    }

    @discardableResult
    private func scheduleAutomaticReconnectIfNeeded() -> Bool {
        guard startsPollingAutomatically,
              connectionKind == .ssh,
              didClose == false,
              lifecycleState == .disconnected || lifecycleState == .connecting,
              automaticReconnectWorkItem == nil,
              let reconnecter
        else {
            return false
        }

        let delay = reconnecter.automaticReconnectDelaySeconds()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.automaticReconnectWorkItem = nil
            guard self.didClose == false,
                  self.lifecycleState == .disconnected || self.lifecycleState == .connecting
            else {
                return
            }
            do {
                _ = try self.reconnectTerminal(trigger: .automatic)
            } catch {
            }
        }
        automaticReconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return true
    }

    private func cancelAutomaticReconnect() {
        automaticReconnectWorkItem?.cancel()
        automaticReconnectWorkItem = nil
    }

    private func isReturnKey(_ bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && bytes.allSatisfy { $0 == 10 || $0 == 13 }
    }

    private static func isTransientPollError(_ error: Error) -> Bool {
        if case let SshRuntimeError.Transport(message) = error {
            return isTransientPollDiagnostic(message)
        }
        let diagnostic = RuntimeDiagnosticFormatter.userMessage(for: error)
        return isTransientPollDiagnostic(diagnostic)
    }

    private static func isTransientPollDiagnostic(_ diagnostic: String) -> Bool {
        let normalized = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.localizedCaseInsensitiveContains("would block")
            || normalized.contains("Session(-37)")
            || normalized == "SSH 通道暂时不可用，请稍后重试"
    }

    @objc
    private func multiExecPauseButtonPressed(_ sender: Any?) {
        setMultiExecPaused(!isMultiExecPaused)
    }

    private func setLifecycle(_ state: RemoteTerminalLifecycleState, message: String) {
        lifecycleState = state
        lifecycleLabel.stringValue = message
        applyLifecyclePresentation()
    }

    private func applyLifecyclePresentation() {
        lifecycleBar.isHidden = lifecycleState == .running
        reconnectButton.isHidden = lifecycleState == .closed
            || lifecycleState == .running
            || lifecycleState == .connecting
            || reconnecter == nil
        reconnectButton.isEnabled = lifecycleState == .disconnected
    }

    private func refreshTerminalAppearanceAfterEffectiveAppearanceChange() {
        let snapshot = settingsStore.snapshot()
        guard snapshot.terminalTheme == .system else {
            return
        }
        terminalView.appearance = terminalView.window?.effectiveAppearance ?? view.effectiveAppearance
        TerminalAppearanceApplier.apply(settings: snapshot, to: terminalView)
    }

    private func observeSettingsChanges() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettingsStore.didChangeNotification,
            object: settingsStore,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let snapshot = self.settingsStore.snapshot()
            TerminalAppearanceApplier.apply(settings: snapshot, to: self.terminalView)
            self.applyTerminalRuntimeSettings(snapshot)
            self.syncLiveShellKeepaliveInterval(snapshot)
            self.commandInputObserver.reset()
            self.commandHistoryInputBuffer.reset()
            self.commandHintOverlay.clear()
        }
    }

    private func terminalEffectiveAppearanceDidChange() {
        guard isViewLoaded else { return }
        let snapshot = settingsStore.snapshot()
        TerminalAppearanceApplier.apply(settings: snapshot, to: terminalView)
        applyTerminalRuntimeSettings(snapshot)
        refreshLineInfoGutter()
        guard commandHintOverlay.presentationKind == .completion,
              commandHintOverlay.isHidden == false
        else { return }
        applyCommandCompletionTheme()
        commandHintOverlay.refreshVisibleCompletionStyle()
        positionCommandCompletionOverlayIfNeeded()
    }

    private func syncLiveShellKeepaliveInterval(_ settings: AppSettings) {
        guard connectionKind == .ssh,
              runtimeID.hasPrefix("pending_") == false
        else {
            return
        }
        try? bridge.setLiveShellKeepaliveInterval(
            runtimeID: runtimeID,
            seconds: UInt32(AppSettings.clampedTerminalKeepAliveIntervalSeconds(settings.terminalKeepAliveIntervalSeconds))
        )
    }

    private func applyTerminalRuntimeSettings(_ settings: AppSettings) {
        lineInfoGutter.apply(settings: settings, terminalView: terminalView)
        let rows = terminalView.terminal.getDims().rows
        lineInfoGutterWidthConstraint?.constant = TerminalLineInfoGutterView.preferredWidth(for: settings, rows: rows)
        terminalLeadingToContainerConstraint?.isActive = false
        terminalLeadingToLineInfoConstraint?.isActive = false
        terminalTopToContainerConstraint?.isActive = false
        terminalTopWithPaddingConstraint?.isActive = false
        terminalTrailingToContainerConstraint?.isActive = false
        terminalTrailingWithPaddingConstraint?.isActive = false
        if settings.terminalLineNumbersEnabled || settings.terminalTimestampsEnabled {
            terminalLeadingToLineInfoConstraint?.isActive = true
        } else {
            terminalLeadingToContainerConstraint?.isActive = true
        }
        if settings.terminalWorkspacePaddingEnabled {
            terminalTopWithPaddingConstraint?.isActive = true
            terminalTrailingWithPaddingConstraint?.isActive = true
        } else {
            terminalTopToContainerConstraint?.isActive = true
            terminalTrailingToContainerConstraint?.isActive = true
        }
    }

    private func refreshLineInfoGutter(date: Date = Date()) {
        lineInfoGutter.refresh(from: terminalView, date: date)
        let settings = settingsStore.snapshot()
        let rows = terminalView.terminal.getDims().rows
        lineInfoGutterWidthConstraint?.constant = TerminalLineInfoGutterView.preferredWidth(for: settings, rows: rows)
    }

    private func recordSubmittedCommands(_ bytes: [UInt8]) {
        for command in commandHistoryInputBuffer.ingest(bytes: bytes) {
            commandSuggestionHistoryCommands.removeAll { $0 == command }
            commandSuggestionHistoryCommands.insert(command, at: 0)
            if commandSuggestionHistoryCommands.count > 200 {
                commandSuggestionHistoryCommands.removeLast(commandSuggestionHistoryCommands.count - 200)
            }
            onCommandSubmitted?(self, command)
        }
    }

    private func renderCommandInputObservation(_ observation: TerminalCommandInputObservation) {
        if let completionSuggestion = observation.completionSuggestion {
            applyCommandCompletionTheme()
            commandHintOverlay.renderCompletion(completionSuggestion)
            positionCommandCompletionOverlayIfNeeded()
        } else if let hint = observation.submittedHint,
                  settingsStore.snapshot().terminalHighlightLevel == .commandLineEnhanced {
            commandHintOverlay.render(hint)
            positionSubmittedCommandHintOverlay()
        } else if observation.submittedHint != nil || observation.completionSuggestion == nil {
            commandHintOverlay.clear()
        }
    }

    private func refreshCommandCompletionFromPathCache() {
        guard lifecycleState == .running else {
            return
        }
        let observation = commandInputObserver.refreshCompletion(
            settings: settingsStore.snapshot(),
            historyCommands: commandSuggestionHistoryCommands,
            pathCompletionProvider: pathCompletionProviderForCurrentInput()
        )
        remoteCompletionInputLine = observation.currentLine
        guard observation.completionSuggestion != nil else {
            return
        }
        renderCommandInputObservation(observation)
    }

    private func pathCompletionProviderForCurrentInput() -> TerminalPathCompletionProviding? {
        if let injectedPathCompletionProvider {
            return injectedPathCompletionProvider
        }
        guard connectionKind == .ssh,
              liveSessionContext != nil
        else {
            return nil
        }
        return liveRemotePathCompletionProvider
    }

    private func applyCommandCompletionTheme() {
        commandHintOverlay.applyCompletionTheme(
            foreground: resolvedTerminalColor(terminalView.nativeForegroundColor),
            background: resolvedTerminalColor(terminalView.nativeBackgroundColor),
            accent: resolvedTerminalColor(terminalView.caretColor)
        )
    }

    private func resolvedTerminalColor(_ color: NSColor) -> NSColor {
        NSColor(cgColor: StacioDesignSystem.resolvedLayerColor(color, for: terminalView)) ?? color
    }

    private func setCommandHintOverlayVisible(_ visible: Bool) {
        if visible == false {
            commandHintWidthConstraint?.isActive = false
        }
        terminalBottomToCommandHintConstraint?.isActive = false
        terminalBottomToContainerConstraint?.isActive = false
        if visible && commandHintOverlay.presentationKind == .submittedHint {
            terminalBottomToCommandHintConstraint?.isActive = true
        } else {
            terminalBottomToContainerConstraint?.isActive = true
        }
        view.needsLayout = true
    }

    private func positionSubmittedCommandHintOverlay() {
        commandHintWidthConstraint?.isActive = false
        commandHintLeadingConstraint?.constant = TerminalCommandHintOverlayLayout.containerMargin
        commandHintBottomConstraint?.constant = -TerminalCommandHintOverlayLayout.containerMargin
        view.layoutSubtreeIfNeeded()
        view.needsLayout = true
    }

    private func positionCommandCompletionOverlayIfNeeded(requiresLayout: Bool = true) {
        guard commandHintOverlay.presentationKind == .completion,
              commandHintOverlay.isHidden == false
        else { return }
        if requiresLayout {
            view.layoutSubtreeIfNeeded()
        }
        guard view.bounds.width >= TerminalCommandHintOverlayLayout.completionMinimumWidth
            + TerminalCommandHintOverlayLayout.containerMargin * 2,
            view.bounds.height >= 120
        else {
            return
        }
        commandHintOverlay.layoutSubtreeIfNeeded()
        let fittingSize = commandHintOverlay.fittingSize
        let targetFrame = TerminalCommandHintOverlayLayout.completionFrame(
            in: view,
            terminalView: terminalView,
            overlaySize: CGSize(
                width: TerminalCommandHintOverlayLayout.completionPreferredWidth,
                height: fittingSize.height
            ),
            caretFrameOverride: remoteCompletionCaretFrameForCurrentInput()
        )
        let targetBottomConstant = -targetFrame.minY
        let needsConstraintUpdate = commandHintWidthConstraint?.isActive != true
            || abs((commandHintWidthConstraint?.constant ?? 0) - targetFrame.width) > 0.5
            || abs((commandHintLeadingConstraint?.constant ?? 0) - targetFrame.minX) > 0.5
            || abs((commandHintBottomConstraint?.constant ?? 0) - targetBottomConstant) > 0.5
        guard needsConstraintUpdate else { return }
        commandHintWidthConstraint?.constant = targetFrame.width
        commandHintWidthConstraint?.isActive = true
        commandHintLeadingConstraint?.constant = targetFrame.minX
        commandHintBottomConstraint?.constant = targetBottomConstant
        if requiresLayout {
            view.layoutSubtreeIfNeeded()
        }
        view.needsLayout = true
    }

    private func resetRemoteInputLineAnchor() {
        remoteInputLineAnchorCaretFrame = nil
        remoteInputLineAnchorLength = 0
        remoteCompletionInputLine = ""
    }

    private func remoteCompletionCaretFrameForCurrentInput() -> NSRect? {
        if remoteInputLineAnchorCaretFrame == nil {
            remoteInputLineAnchorCaretFrame = TerminalCommandHintOverlayLayout.caretFrame(for: terminalView)
            remoteInputLineAnchorLength = 0
        }
        guard let anchor = remoteInputLineAnchorCaretFrame,
              anchor.width > 0,
              anchor.height > 0
        else { return nil }
        let text = remoteCompletionInputLine.isEmpty
            ? String(decoding: remoteInputLineBuffer, as: UTF8.self)
            : remoteCompletionInputLine
        let characterOffset = CGFloat(max(0, text.count - remoteInputLineAnchorLength)) * anchor.width
        return NSRect(
            x: anchor.minX + characterOffset,
            y: anchor.minY,
            width: anchor.width,
            height: anchor.height
        )
    }

    private func focusTerminalViewForKeyboardInput() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.lifecycleState == .running,
                  self.terminalView.window?.firstResponder !== self.terminalView
            else { return }
            self.terminalView.window?.makeFirstResponder(self.terminalView)
        }
    }

    @objc
    private func reconnectButtonPressed() {
        _ = try? reconnectTerminal()
    }
}
