import AppKit
import StacioAgentBridge
import SwiftTerm

public protocol LocalTerminalProcessLaunching {
    func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool
    func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    )
    func terminate(_ terminalView: LocalProcessTerminalView)
    func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView)
}

public struct SwiftTermLocalTerminalProcessLauncher: LocalTerminalProcessLaunching {
    public init() {}

    public func isRunning(_ terminalView: LocalProcessTerminalView) -> Bool {
        terminalView.process.running
    }

    public func startProcess(
        in terminalView: LocalProcessTerminalView,
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        terminalView.startProcess(
            executable: executable,
            args: args,
            environment: environment,
            execName: execName,
            currentDirectory: currentDirectory
        )
    }

    public func terminate(_ terminalView: LocalProcessTerminalView) {
        terminalView.terminate()
    }

    public func sendInput(_ bytes: [UInt8], to terminalView: LocalProcessTerminalView) {
        if let stacioTerminalView = terminalView as? StacioLocalTerminalView {
            stacioTerminalView.sendProgrammaticInput(bytes)
            return
        }
        terminalView.send(data: ArraySlice(bytes))
    }
}

public final class TerminalPaneViewController: NSViewController, LocalProcessTerminalViewDelegate {
    public let runtimeID: String
    public let shellPath: String
    public let terminalView: StacioLocalTerminalView
    public var keyboardFocusView: NSView { terminalView }
    public var onUserInput: ((TerminalPaneViewController, [UInt8]) -> Bool)?
    public var onAIContextRequest: ((TerminalAIContextRequest) -> Void)?
    public var onCommandSubmitted: ((TerminalPaneViewController, String) -> Void)?
    public var onCommandFinished: ((TerminalPaneViewController) -> Void)?
    public private(set) var currentLocalDirectory: String?
    public private(set) var commandCompletionGeneration: UInt64 = 0
    private var agentInteractionLocked = false

    private let eventSink: TerminalEventSink
    private let transcriptRecorder: TranscriptRecorder
    private let settingsStore: AppSettingsStore
    private let processLauncher: LocalTerminalProcessLaunching
    private let linkOpener: TerminalLinkOpening
    private let agentTraceController = TerminalTraceController()
    private let commandInputObserver = TerminalCommandInputObserver()
    private let commandHistoryInputBuffer = TerminalCommandHistoryInputBuffer()
    private var commandSuggestionHistoryCommands: [String] = []
    private let commandHintOverlay = TerminalCommandHintOverlayView()
    private let agentTraceOverlay = TerminalAgentTraceOverlayView(frame: .zero)
    private let agentInteractionGlow = TerminalAgentInteractionGlowView(frame: .zero)
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
    private let autoStartProcess: Bool
    private lazy var terminalContextMenuController = TerminalContextMenuController(
        runtimeID: runtimeID,
        paste: { [weak self] in
            self?.pasteClipboard()
        },
        askAI: { [weak self] request in
            self?.onAIContextRequest?(request)
        }
    )
    private var settingsObserver: NSObjectProtocol?
    private var didClose = false

    public init(
        runtimeID: String,
        shellPath: String,
        eventSink: TerminalEventSink,
        transcriptRecorder: TranscriptRecorder = TranscriptRecorder(),
        settingsStore: AppSettingsStore = .shared,
        processLauncher: LocalTerminalProcessLaunching = SwiftTermLocalTerminalProcessLauncher(),
        linkOpener: TerminalLinkOpening? = nil,
        autoStartProcess: Bool = true
    ) {
        self.runtimeID = runtimeID
        self.shellPath = shellPath
        self.eventSink = eventSink
        self.transcriptRecorder = transcriptRecorder
        self.settingsStore = settingsStore
        self.processLauncher = processLauncher
        self.linkOpener = linkOpener ?? WorkspaceTerminalLinkOpener.shared
        self.autoStartProcess = autoStartProcess
        self.terminalView = StacioLocalTerminalView(frame: .zero)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func loadView() {
        let container = TerminalFocusContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onEffectiveAppearanceChanged = { [weak self] in
            self?.terminalEffectiveAppearanceDidChange()
        }

        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.fontZoomSettingsStore = settingsStore
        terminalView.notifyUpdateChanges = true
        TerminalAppearanceApplier.apply(settings: settingsStore.snapshot(), to: terminalView)
        observeSettingsChanges()
        terminalView.contextMenuProvider = { [weak self] selectedText in
            self?.terminalContextMenuController.makeMenu(selectedText: selectedText)
        }
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] bytes in
            guard let self else { return }
            self.transcriptRecorder.append(bytes: bytes)
            TerminalOutputBroadcastHub.shared.publishOutput(runtimeID: self.runtimeID, bytes: bytes)
            try? self.eventSink.terminalDidProduceOutput(runtimeID: self.runtimeID, bytes: bytes)
        }
        terminalView.onUserInput = { [weak self] bytes in
            self?.handleUserInput(bytes) ?? false
        }
        terminalView.onSearchViewportChanged = { [weak self] in
            guard let self else { return }
            self.terminalSearchController.terminalContentDidChange()
            self.refreshLineInfoGutter()
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
            commandHintLeading,
            commandHintOverlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            commandHintBottom,
            commandHintOverlay.widthAnchor.constraint(
                lessThanOrEqualToConstant: TerminalCommandHintOverlayLayout.submittedPreferredMaxWidth
            ),
            agentTraceOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            agentTraceOverlay.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            agentTraceOverlay.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            agentTraceOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])
        applyTerminalRuntimeSettings(settingsStore.snapshot())

        view = container
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        positionCommandCompletionOverlayIfNeeded(requiresLayout: false)
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        focusTerminalViewForKeyboardInput()

        if autoStartProcess && processLauncher.isRunning(terminalView) == false {
            let launch = Self.localShellLaunchConfiguration(shellPath: shellPath)
            processLauncher.startProcess(
                in: terminalView,
                executable: launch.executable,
                args: launch.args,
                environment: {
                    let settings = settingsStore.snapshot()
                    return TerminalHighlighting.shellEnvironment(
                        level: settings.terminalHighlightLevel,
                        shellName: launch.shellName,
                        x11Display: settings.terminalX11Display
                    )
                }(),
                execName: launch.execName,
                currentDirectory: nil
            )
        }
    }

    private static func localShellLaunchConfiguration(shellPath: String) -> (
        executable: String,
        args: [String],
        execName: String?,
        shellName: String?
    ) {
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let shellExecutable = quotedShellCommandArgument(shellPath)
        switch shellName {
        case "zsh":
            return (
                shellPath,
                ["-l", "-c", "eval \"$STACIO_OSC7_BOOTSTRAP\"; exec \(shellExecutable) -l"],
                "-zsh",
                shellName
            )
        case "bash":
            return (
                shellPath,
                ["-l", "-c", "eval \"$STACIO_OSC7_BOOTSTRAP\"; exec \(shellExecutable) -l"],
                "-bash",
                shellName
            )
        case "fish":
            return (
                shellPath,
                ["-lc", "eval \"$STACIO_OSC7_BOOTSTRAP\"; exec \(shellExecutable) -l"],
                "fish",
                shellName
            )
        default:
            return (shellPath, ["-l"], nil, nil)
        }
    }

    private static func quotedShellCommandArgument(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"\(escaped)\""
    }

    public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        guard TerminalResizeValidator.shouldForward(cols: newCols, rows: newRows) else { return }
        try? eventSink.terminalDidResize(runtimeID: runtimeID, cols: newCols, rows: newRows)
        refreshLineInfoGutter()
    }

    public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let normalized = TerminalCurrentDirectoryNormalizer.normalize(directory) else {
            return
        }
        currentLocalDirectory = normalized
        commandCompletionGeneration &+= 1
        onCommandFinished?(self)
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

    public func processTerminated(source: TerminalView, exitCode: Int32?) {
        notifyClosed()
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

    private func copyTerminalPathToPasteboard(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    public func terminalContextMenuForTesting(selectedText: String?) -> NSMenu {
        terminalContextMenuController.makeMenu(selectedText: selectedText)
    }

    public func showFind() {
        terminalSearchController.show()
    }

    public func closeTerminal() {
        processLauncher.terminate(terminalView)
        notifyClosed()
    }

    public func sendInput(_ bytes: [UInt8]) {
        TerminalOutputBroadcastHub.shared.publishUserInput(runtimeID: runtimeID, bytes: bytes)
        processLauncher.sendInput(bytes, to: terminalView)
        recordSubmittedCommands(bytes)
    }

    public func sendAgentInput(_ bytes: [UInt8]) {
        processLauncher.sendInput(bytes, to: terminalView)
        recordSubmittedCommands(bytes)
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
            title: title ?? L10n.Workspace.local,
            event: event
        )
    }

    public var terminalOutputTranscript: String {
        transcriptRecorder.snapshot
    }

    public var terminalDisplaySnapshotForTesting: String {
        String(data: terminalView.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
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

    public var lineInfoGutterColorForTesting: NSColor? {
        lineInfoGutter.lineInfoColorForTesting
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

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    private func notifyClosed() {
        guard didClose == false else { return }
        didClose = true
        try? eventSink.terminalDidClose(runtimeID: runtimeID)
    }

    private func focusTerminalViewForKeyboardInput() {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.terminalView.window?.firstResponder !== self.terminalView
            else { return }
            self.terminalView.window?.makeFirstResponder(self.terminalView)
        }
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
            self.commandInputObserver.reset()
            self.commandHistoryInputBuffer.reset()
            self.commandHintOverlay.clear()
        }
    }

    private func terminalEffectiveAppearanceDidChange() {
        guard isViewLoaded else { return }
        let snapshot = settingsStore.snapshot()
        terminalView.appearance = terminalView.window?.effectiveAppearance ?? view.effectiveAppearance
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

    private func handleUserInput(_ bytes: [UInt8]) -> Bool {
        if agentInteractionLocked { return true }
        if onUserInput?(self, bytes) == true { return true }
        let observation = commandInputObserver.ingest(
            bytes: bytes,
            settings: settingsStore.snapshot(),
            historyCommands: commandSuggestionHistoryCommands,
            pathCompletionProvider: LocalTerminalPathCompletionProvider(currentDirectory: currentLocalDirectory)
        )
        renderCommandInputObservation(observation)
        if let acceptedCompletionBytes = observation.acceptedCompletionBytes {
            TerminalOutputBroadcastHub.shared.publishUserInput(runtimeID: runtimeID, bytes: acceptedCompletionBytes)
            processLauncher.sendInput(acceptedCompletionBytes, to: terminalView)
            recordSubmittedCommands(acceptedCompletionBytes)
            return true
        }
        if observation.shouldConsumeInput {
            return true
        }
        TerminalOutputBroadcastHub.shared.publishUserInput(runtimeID: runtimeID, bytes: bytes)
        recordSubmittedCommands(bytes)
        return false
    }

    public func setAgentInteractionLocked(_ locked: Bool) {
        agentInteractionLocked = locked
        agentInteractionGlow.setActive(locked)
    }

    public var agentInteractionGlowActiveForTesting: Bool {
        agentInteractionGlow.isActiveForTesting
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
            )
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
}
