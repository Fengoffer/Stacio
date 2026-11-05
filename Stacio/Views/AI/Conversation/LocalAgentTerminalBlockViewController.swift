import AppKit

private struct FrozenLocalAgentToolResolver: LocalAgentToolResolving {
    let configuration: LocalAgentPassthroughConfiguration
    let upstream: LocalAgentToolResolving

    func executablePath(for tool: LocalAgentTool) -> String? {
        passthroughConfiguration(for: tool)?.executablePath
    }

    func passthroughConfiguration(for tool: LocalAgentTool) -> LocalAgentPassthroughConfiguration? {
        guard tool == configuration.tool,
              upstream.passthroughConfiguration(for: tool) == configuration
        else { return nil }
        return configuration
    }
}

private struct LegacyPathLocalAgentToolResolver: LocalAgentToolResolving {
    let tool: LocalAgentTool
    let executablePath: String

    func executablePath(for candidate: LocalAgentTool) -> String? {
        candidate == tool ? executablePath : nil
    }

    func legacyExecutablePath(for candidate: LocalAgentTool) -> String? {
        executablePath(for: candidate)
    }
}

enum LocalAgentTerminalBlockState: Equatable {
    case hidden
    case ready(LocalAgentTool)
    case running(LocalAgentTool, executable: String)
    case terminating(LocalAgentTool)
    case terminated(LocalAgentTool, exitCode: Int32?)
    case unavailable(LocalAgentTool)
    case blocked(LocalAgentTool, reason: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isTerminating: Bool {
        if case .terminating = self { return true }
        return false
    }

    var preventsRuntimeChange: Bool {
        switch self {
        case .running, .terminating:
            return true
        case .hidden, .ready, .terminated, .unavailable, .blocked:
            return false
        }
    }
}

/// V2's honest fallback for CLI agents that expose only a PTY. The terminal is
/// kept inside the conversation shell, while its bytes remain terminal bytes:
/// they are never projected as model deltas, tool calls, approvals, or completion.
@MainActor
final class LocalAgentTerminalBlockViewController: NSViewController {
    var onStateChange: ((LocalAgentTerminalBlockState) -> Void)? {
        didSet { onStateChange?(state) }
    }

    private(set) var state: LocalAgentTerminalBlockState = .hidden {
        didSet {
            updatePresentation()
            onStateChange?(state)
        }
    }

    private let resolver: LocalAgentToolResolving
    private let processLauncherFactory: () -> LocalTerminalProcessLaunching
    private let settingsStore: AppSettingsStore
    private let currentDirectoryProvider: () -> String?
    private let bridgeContextProvider: () -> LocalAgentBridgeContext?
    private let workingDirectorySelector: @MainActor () -> String?
    private let runtimeLaunchAuthorizer: LocalAgentRuntimeLaunchAuthorizing?

    private let headerView = NSView()
    private let statusImage = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Stacio Agent")
    private let statusLabel = NSTextField(labelWithString: "终端透传 · 未选择配置")
    private let focusButton = NSButton()
    private let collapseButton = NSButton()
    private let separator = NSBox()
    private let terminalHost = NSView()
    private var sessionsByTool: [LocalAgentTool: LocalAgentSessionViewController] = [:]
    private var sessionConfigurationsByTool: [LocalAgentTool: LocalAgentPassthroughConfiguration] = [:]
    private var legacySessionExecutablePathsByTool: [LocalAgentTool: String] = [:]
    private(set) var selectedTool: LocalAgentTool?
    private(set) var selectedConfiguration: LocalAgentPassthroughConfiguration?
    private(set) var selectedLegacyExecutablePath: String?
    private(set) var sentHistory: [String] = []
    private(set) var lastPreparedWorkingDirectoryForTesting: String?
    private var userCollapsed = false
    private var compactPresentation = false

    init(
        resolver: LocalAgentToolResolving,
        processLauncherFactory: @escaping () -> LocalTerminalProcessLaunching,
        settingsStore: AppSettingsStore = .shared,
        currentDirectoryProvider: @escaping () -> String? = { nil },
        bridgeContextProvider: @escaping () -> LocalAgentBridgeContext? = { nil },
        workingDirectorySelector: @escaping @MainActor () -> String? = {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "选择"
            panel.message = "选择本轮 Stacio Agent 使用的 Mac 本地工作目录。"
            return panel.runModal() == .OK ? panel.url?.path : nil
        },
        runtimeLaunchAuthorizer: LocalAgentRuntimeLaunchAuthorizing?
    ) {
        self.resolver = resolver
        self.processLauncherFactory = processLauncherFactory
        self.settingsStore = settingsStore
        self.currentDirectoryProvider = currentDirectoryProvider
        self.bridgeContextProvider = bridgeContextProvider
        self.workingDirectorySelector = workingDirectorySelector
        self.runtimeLaunchAuthorizer = runtimeLaunchAuthorizer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 250))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = StacioDesignSystem.theme.panelCornerRadius
        surface.layer?.cornerCurve = .continuous
        surface.layer?.borderWidth = 1
        StacioDesignSystem.setLayerBackgroundColor(
            surface,
            color: NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        )
        StacioDesignSystem.setLayerBorderColor(
            surface,
            color: NSColor.separatorColor.withAlphaComponent(0.34)
        )
        surface.setAccessibilityIdentifier("Stacio.AI.localAgentTerminalBlock")
        surface.isHidden = true
        view = surface
        configureHierarchy()
        updatePresentation()
    }

    @discardableResult
    func activate(tool: LocalAgentTool) -> Bool {
        guard let configuration = resolver.passthroughConfiguration(for: tool),
              select(configuration: configuration)
        else {
            selectedTool = tool
            view.isHidden = false
            state = .unavailable(tool)
            return false
        }
        guard case .ready(let prepared) = prepareWorkingDirectoryForNextInput(
            configuration: configuration
        ) else { return false }
        guard let session = session(for: configuration) else { return false }
        session.startIfNeeded(preparedWorkingDirectory: prepared)
        synchronizeState(from: session.launchState, tool: tool)
        return session.launchState.isRunning
    }

    /// Restores the pre-V2 Inspector behavior for an already-installed CLI
    /// when Settings has no verified profile yet. The caller must present this
    /// as compatibility mode; it never enters the durable V2 Runtime router.
    @discardableResult
    func selectLegacy(tool: LocalAgentTool) -> Bool {
        loadViewIfNeeded()
        if state.preventsRuntimeChange {
            guard selectedTool == tool,
                  selectedConfiguration == nil,
                  selectedLegacyExecutablePath != nil else {
                showNotice("请先停止当前 Stacio Agent，再切换 Runtime。")
                return false
            }
            // The running PTY owns a frozen executable. A PATH mutation after
            // launch must not hide its Stop control or invalidate further input.
            view.isHidden = false
            return true
        }
        guard let executablePath = resolver.legacyExecutablePath(for: tool) else {
            selectedTool = tool
            selectedConfiguration = nil
            selectedLegacyExecutablePath = nil
            view.isHidden = false
            state = .unavailable(tool)
            return false
        }
        if sessionConfigurationsByTool[tool] != nil
            || legacySessionExecutablePathsByTool[tool].map({ $0 != executablePath }) == true {
            removeSession(for: tool)
        }
        selectedTool = tool
        selectedConfiguration = nil
        selectedLegacyExecutablePath = executablePath
        view.isHidden = false
        sessionsByTool.values.forEach { $0.view.isHidden = $0.tool != tool }
        state = .ready(tool)
        return true
    }

    /// 选择下一轮 Runtime 只准备 UI，不启动 CLI。启动与首条 PTY 写入发生在 durable
    /// Turn/outbox 已提交之后。
    func canSelect(configuration: LocalAgentPassthroughConfiguration) -> Bool {
        let changesRunningRuntime = state.preventsRuntimeChange
            && (selectedTool != configuration.tool || selectedConfiguration != configuration)
        return changesRunningRuntime == false
            && configuration.isReadyForTerminalPassthrough
            && resolver.passthroughConfiguration(for: configuration.tool) == configuration
    }

    @discardableResult
    func select(configuration: LocalAgentPassthroughConfiguration) -> Bool {
        loadViewIfNeeded()
        let tool = configuration.tool
        if state.preventsRuntimeChange,
           selectedTool != tool || selectedConfiguration != configuration {
            showNotice("请先停止当前 Stacio Agent，再切换 Runtime。")
            return false
        }
        if selectedTool == tool,
           selectedConfiguration == configuration,
           state.preventsRuntimeChange {
            view.isHidden = false
            return true
        }
        guard canSelect(configuration: configuration) else {
            selectedTool = tool
            selectedConfiguration = nil
            selectedLegacyExecutablePath = nil
            view.isHidden = false
            state = .unavailable(tool)
            return false
        }

        if legacySessionExecutablePathsByTool[tool] != nil {
            removeSession(for: tool)
        }
        if let previous = sessionConfigurationsByTool[tool], previous != configuration {
            removeSession(for: tool)
        }

        selectedTool = tool
        selectedConfiguration = configuration
        selectedLegacyExecutablePath = nil
        view.isHidden = false
        sessionsByTool.values.forEach { $0.view.isHidden = $0.tool != tool }
        state = .ready(tool)
        return true
    }

    @discardableResult
    func deactivateIfStopped() -> Bool {
        guard state.preventsRuntimeChange == false else {
            showNotice("Stacio Agent 仍在运行。请先停止会话，再切换到 Native。")
            return false
        }
        selectedTool = nil
        selectedConfiguration = nil
        selectedLegacyExecutablePath = nil
        view.isHidden = true
        state = .hidden
        return true
    }

    @discardableResult
    func send(
        _ text: String,
        preparedWorkingDirectory: LocalAgentPreparedWorkingDirectory? = nil
    ) -> LocalAgentInputSendResult {
        guard let selectedTool else { return .notRunning }
        if selectedConfiguration == nil,
           let selectedLegacyExecutablePath {
            let existing = sessionsByTool[selectedTool]
            let existingOwnsFrozenPath = existing != nil
                && legacySessionExecutablePathsByTool[selectedTool] == selectedLegacyExecutablePath
            let existingProcessIsActive = existing?.launchState.isRunning == true
                || existing?.launchState == .terminating
            guard existingOwnsFrozenPath && existingProcessIsActive
                    || resolver.legacyExecutablePath(for: selectedTool) == selectedLegacyExecutablePath
            else {
                state = .unavailable(selectedTool)
                return .configurationChanged
            }
            guard let session = legacySession(for: selectedTool, executablePath: selectedLegacyExecutablePath) else {
                return .notRunning
            }
            let result = session.sendAgentInput(text)
            synchronizeState(from: session.launchState, tool: selectedTool)
            if result == .accepted {
                sentHistory.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result
        }
        guard let selectedConfiguration else { return .notRunning }
        guard resolver.passthroughConfiguration(for: selectedTool) == selectedConfiguration else {
            state = .unavailable(selectedTool)
            return .configurationChanged
        }
        let resolvedPreparation: LocalAgentPreparedWorkingDirectory
        if let preparedWorkingDirectory {
            resolvedPreparation = preparedWorkingDirectory
        } else {
            switch prepareWorkingDirectoryForNextInput(configuration: selectedConfiguration) {
            case .ready(let prepared):
                resolvedPreparation = prepared
            case .cancelled:
                showNotice("已取消选择工作目录；输入未发送。")
                return .workingDirectorySelectionCancelled
            case .unavailable:
                showNotice("所选 Mac 本地目录不可用；输入未发送。")
                return .workingDirectoryUnavailable
            case .changeRequiresRestart:
                showNotice("当前 Stacio Agent 已绑定其他工作目录，请先停止后再发送。")
                return .workingDirectoryChangeRequiresRestart
            }
        }
        guard let session = session(for: selectedConfiguration) else { return .notRunning }
        let result = session.sendAgentInput(
            text,
            preparedWorkingDirectory: resolvedPreparation
        )
        switch result {
        case .accepted:
            sentHistory.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .missingExecutable:
            state = .unavailable(selectedTool)
        case .configurationChanged:
            state = .unavailable(selectedTool)
        case .launchBlocked(let reason):
            state = .blocked(selectedTool, reason: reason)
        case .workingDirectorySelectionCancelled:
            showNotice("已取消选择工作目录；输入未发送。")
        case .workingDirectoryUnavailable:
            showNotice("所选 Mac 本地目录不可用；输入未发送。")
        case .workingDirectoryChangeRequiresRestart:
                showNotice("当前 Stacio Agent 已绑定其他工作目录，请先停止后再发送。")
        case .terminating:
            state = .terminating(selectedTool)
        case .sensitiveInputRequired:
            showNotice("终端正在等待敏感输入，请直接在终端中输入。")
        case .notRunning:
            synchronizeState(from: session.launchState, tool: selectedTool)
        }
        return result
    }

    enum WorkingDirectoryPreparationResult: Equatable {
        case ready(LocalAgentPreparedWorkingDirectory)
        case cancelled
        case unavailable
        case changeRequiresRestart
    }

    func prepareWorkingDirectoryForNextInput(
        configuration: LocalAgentPassthroughConfiguration
    ) -> WorkingDirectoryPreparationResult {
        guard canSelect(configuration: configuration) else { return .unavailable }
        let prepared: LocalAgentPreparedWorkingDirectory
        switch configuration.workingDirectoryMode {
        case .managedWorkspace:
            prepared = LocalAgentPreparedWorkingDirectory(
                mode: .managedWorkspace,
                localPathReference: nil
            )
        case .userSelectedLocalDirectory:
            guard let reference = configuration.workingDirectoryReference,
                  LocalAgentWorkingDirectoryValidator.canonicalExistingDirectory(reference) != nil
            else { return .unavailable }
            prepared = LocalAgentPreparedWorkingDirectory(
                mode: .userSelectedLocalDirectory,
                localPathReference: reference
            )
        case .askEveryTurn:
            guard let selected = workingDirectorySelector() else { return .cancelled }
            guard let canonical = LocalAgentWorkingDirectoryValidator
                .canonicalExistingDirectory(selected)
            else { return .unavailable }
            prepared = LocalAgentPreparedWorkingDirectory(
                mode: .askEveryTurn,
                localPathReference: canonical
            )
        }
        if let session = sessionsByTool[configuration.tool],
           session.launchState.isRunning,
           configuration.workingDirectoryMode == .askEveryTurn,
           session.activeWorkingDirectoryForTesting != prepared.localPathReference {
            return .changeRequiresRestart
        }
        lastPreparedWorkingDirectoryForTesting = prepared.localPathReference
        return .ready(prepared)
    }

    func stop() {
        guard let selectedTool, let session = sessionsByTool[selectedTool] else { return }
        session.terminateSession()
        synchronizeState(from: session.launchState, tool: selectedTool)
    }

    var requiresHostClosureTermination: Bool {
        sessionsByTool.values.contains { session in
            switch session.launchState {
            case .running, .terminating:
                return true
            case .idle, .missingExecutable, .blocked, .terminated:
                return false
            }
        }
    }

    func terminateForHostClosure() {
        for (tool, session) in sessionsByTool {
            session.terminateSession()
            if tool == selectedTool {
                synchronizeState(from: session.launchState, tool: tool)
            }
        }
    }

    func refreshBridgeContext() {
        guard let selectedTool, let session = sessionsByTool[selectedTool] else { return }
        session.refreshBridgeContext()
        synchronizeState(from: session.launchState, tool: selectedTool)
    }

    func focusTerminal() {
        guard let selectedTool, let session = sessionsByTool[selectedTool] else { return }
        session.focusTerminal()
    }

    func showNotice(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.toolTip = message
        statusLabel.textColor = .systemOrange
    }

    var statusTextForTesting: String { statusLabel.stringValue }
    var isTerminalBodyVisibleForTesting: Bool { terminalHost.isHidden == false }
    var isCompactPresentationForTesting: Bool { compactPresentation }

    /// The conversation shell may temporarily reclaim vertical space while a
    /// decision card or the composer needs to remain usable. This does not
    /// overwrite the user's collapse preference; expanding the shell restores
    /// the prior choice.
    func setCompactPresentation(_ compact: Bool) {
        guard compactPresentation != compact else { return }
        compactPresentation = compact
        guard isViewLoaded else { return }
        updateCollapsedPresentation()
    }
    var terminalVisibleForTesting: Bool { view.isHidden == false && terminalHost.isHidden == false }
    var activeSessionForTesting: LocalAgentSessionViewController? {
        selectedTool.flatMap { sessionsByTool[$0] }
    }

    private func session(
        for configuration: LocalAgentPassthroughConfiguration
    ) -> LocalAgentSessionViewController? {
        let tool = configuration.tool
        if let existing = sessionsByTool[tool] {
            existing.view.isHidden = false
            existing.refreshBridgeContext()
            return existing
        }
        let session = makeSession(for: configuration)
        sessionsByTool[tool] = session
        sessionConfigurationsByTool[tool] = configuration
        addChild(session)
        terminalHost.addSubview(session.view)
        session.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            session.view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            session.view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor)
        ])
        sessionsByTool.values.forEach { $0.view.isHidden = $0.tool != tool }
        session.refreshBridgeContext()
        return session
    }

    private func legacySession(
        for tool: LocalAgentTool,
        executablePath: String
    ) -> LocalAgentSessionViewController? {
        if let existing = sessionsByTool[tool],
           legacySessionExecutablePathsByTool[tool] == executablePath {
            existing.view.isHidden = false
            existing.refreshBridgeContext()
            return existing
        }
        if sessionsByTool[tool] != nil {
            removeSession(for: tool)
        }
        let session = LocalAgentSessionViewController(
            tool: tool,
            resolver: LegacyPathLocalAgentToolResolver(
                tool: tool,
                executablePath: executablePath
            ),
            processLauncher: processLauncherFactory(),
            settingsStore: settingsStore,
            currentDirectoryProvider: currentDirectoryProvider,
            bridgeContextProvider: bridgeContextProvider,
            requiresVerifiedConfiguration: false,
            runtimeLaunchAuthorizer: nil
        )
        session.onStatusChange = { [weak self, weak session] launchState in
            guard let self,
                  self.selectedTool == tool,
                  self.sessionsByTool[tool] === session else { return }
            self.synchronizeState(from: launchState, tool: tool)
        }
        sessionsByTool[tool] = session
        legacySessionExecutablePathsByTool[tool] = executablePath
        addChild(session)
        terminalHost.addSubview(session.view)
        session.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            session.view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            session.view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            session.view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            session.view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor)
        ])
        sessionsByTool.values.forEach { $0.view.isHidden = $0.tool != tool }
        session.refreshBridgeContext()
        return session
    }

    private func removeSession(for tool: LocalAgentTool) {
        if let staleSession = sessionsByTool.removeValue(forKey: tool) {
            staleSession.view.removeFromSuperview()
            staleSession.removeFromParent()
        }
        sessionConfigurationsByTool.removeValue(forKey: tool)
        legacySessionExecutablePathsByTool.removeValue(forKey: tool)
    }

    private func makeSession(
        for configuration: LocalAgentPassthroughConfiguration
    ) -> LocalAgentSessionViewController {
        let tool = configuration.tool
        let frozenResolver = FrozenLocalAgentToolResolver(
            configuration: configuration,
            upstream: resolver
        )
        let session = LocalAgentSessionViewController(
            tool: tool,
            resolver: frozenResolver,
            processLauncher: processLauncherFactory(),
            settingsStore: settingsStore,
            currentDirectoryProvider: currentDirectoryProvider,
            bridgeContextProvider: bridgeContextProvider,
            requiresVerifiedConfiguration: true,
            runtimeLaunchAuthorizer: runtimeLaunchAuthorizer
        )
        session.onStatusChange = { [weak self, weak session] launchState in
            guard let self,
                  self.selectedTool == tool,
                  self.sessionsByTool[tool] === session else { return }
            self.synchronizeState(from: launchState, tool: tool)
        }
        return session
    }

    private func synchronizeState(from launchState: LocalAgentSessionLaunchState, tool: LocalAgentTool) {
        switch launchState {
        case .idle:
            state = .ready(tool)
        case .missingExecutable:
            state = .unavailable(tool)
        case .blocked(let reason):
            state = .blocked(tool, reason: reason)
        case .running(let executable):
            state = .running(tool, executable: executable)
        case .terminating:
            state = .terminating(tool)
        case .terminated(let exitCode):
            state = .terminated(tool, exitCode: exitCode)
        }
    }

    private func configureHierarchy() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        statusImage.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [titleLabel, statusLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(
            focusButton,
            symbol: "terminal",
            tooltip: "聚焦 Stacio Agent 终端",
            action: #selector(focusTerminalAction)
        )
        configureIconButton(
            collapseButton,
            symbol: "chevron.down",
            tooltip: "折叠终端块",
            action: #selector(toggleCollapsed)
        )

        headerView.addSubview(statusImage)
        headerView.addSubview(labels)
        headerView.addSubview(focusButton)
        headerView.addSubview(collapseButton)
        NSLayoutConstraint.activate([
            headerView.heightAnchor.constraint(equalToConstant: 42),
            statusImage.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            statusImage.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            statusImage.widthAnchor.constraint(equalToConstant: 14),
            statusImage.heightAnchor.constraint(equalToConstant: 14),
            labels.leadingAnchor.constraint(equalTo: statusImage.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            focusButton.leadingAnchor.constraint(greaterThanOrEqualTo: labels.trailingAnchor, constant: 8),
            focusButton.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -2),
            focusButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            collapseButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            collapseButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor)
        ])

        separator.boxType = .separator
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.wantsLayer = true
        terminalHost.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        terminalHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let minimumTerminalHeight = terminalHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        minimumTerminalHeight.priority = .defaultHigh
        let preferredTerminalHeight = terminalHost.heightAnchor.constraint(equalToConstant: 220)
        preferredTerminalHeight.priority = .defaultLow
        NSLayoutConstraint.activate([minimumTerminalHeight, preferredTerminalHeight])

        let stack = NSStackView(views: [headerView, separator, terminalHost])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        tooltip: String,
        action: Selector
    ) {
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

    private func updatePresentation() {
        guard isViewLoaded else { return }
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.toolTip = nil
        switch state {
        case .hidden:
            titleLabel.stringValue = "Stacio Agent"
            statusLabel.stringValue = "终端透传 · 未选择配置"
            statusImage.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "未启动")
            statusImage.contentTintColor = .secondaryLabelColor
        case .ready(let tool):
            titleLabel.stringValue = "Stacio Agent · \(displayName(for: tool))"
            statusLabel.stringValue = "\(passthroughEvidenceLabel()) · 准备启动"
            statusImage.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "准备启动")
            statusImage.contentTintColor = .secondaryLabelColor
        case .running(let tool, let executable):
            titleLabel.stringValue = "Stacio Agent · \(displayName(for: tool))"
            statusLabel.stringValue = "\(passthroughEvidenceLabel()) · 运行中"
            statusLabel.toolTip = executable
            statusImage.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "运行中")
            statusImage.contentTintColor = .systemGreen
        case .terminating(let tool):
            titleLabel.stringValue = "Stacio Agent · \(displayName(for: tool))"
            statusLabel.stringValue = "正在停止终端会话…"
            statusImage.image = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: "正在停止")
            statusImage.contentTintColor = .systemOrange
        case .terminated(let tool, let exitCode):
            titleLabel.stringValue = "Stacio Agent · \(displayName(for: tool))"
            statusLabel.stringValue = exitCode.map { "终端会话已退出 · code \($0)" } ?? "终端会话已退出 · 状态未知"
            statusImage.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "已退出")
            statusImage.contentTintColor = .secondaryLabelColor
        case .unavailable(let tool):
            titleLabel.stringValue = "Stacio Agent · \(displayName(for: tool))"
            statusLabel.stringValue = "本地命令不可用，请重新检测或在设置中配置。"
            statusLabel.textColor = .systemOrange
            statusImage.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "不可用")
            statusImage.contentTintColor = .systemOrange
        case .blocked(let tool, let reason):
            titleLabel.stringValue = "Stacio Agent · \(displayName(for: tool))"
            statusLabel.stringValue = reason
            statusLabel.toolTip = reason
            statusLabel.textColor = .systemOrange
            statusImage.image = NSImage(
                systemSymbolName: "exclamationmark.shield",
                accessibilityDescription: "启动已阻止"
            )
            statusImage.contentTintColor = .systemOrange
        }
        if case .running = state {
            focusButton.isEnabled = true
        } else {
            focusButton.isEnabled = false
        }
        if case .terminating = state {
            collapseButton.isEnabled = false
        } else {
            collapseButton.isEnabled = true
        }
    }

    private func displayName(for tool: LocalAgentTool) -> String {
        guard selectedConfiguration?.tool == tool else { return tool.displayName }
        return selectedConfiguration?.displayName ?? tool.displayName
    }

    private func passthroughEvidenceLabel() -> String {
        if selectedConfiguration == nil, selectedLegacyExecutablePath != nil {
            return "终端透传 · 兼容本地 CLI"
        }
        let level: String
        switch selectedConfiguration?.supportLevel {
        case .ga: level = "GA"
        case .experimental: level = "Experimental"
        case .unsupported: level = "Unsupported"
        case nil: level = "未验证"
        }
        return "终端透传 · 已确认路径 · \(level)"
    }

    @objc private func focusTerminalAction() {
        focusTerminal()
    }

    @objc private func toggleCollapsed() {
        userCollapsed.toggle()
        updateCollapsedPresentation()
    }

    private func updateCollapsedPresentation() {
        let collapsed = userCollapsed || compactPresentation
        terminalHost.isHidden = collapsed
        separator.isHidden = collapsed
        let symbol = collapsed ? "chevron.right" : "chevron.down"
        let tooltip = collapsed ? "展开终端块" : "折叠终端块"
        collapseButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        collapseButton.toolTip = tooltip
        collapseButton.setAccessibilityLabel(tooltip)
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.needsLayout = true
    }
}
