import AppKit
import StacioCoreBindings

public struct TunnelLiveSessionContext {
    public let config: SshConnectionConfig
    public let secret: SshAuthSecret
    public let expectedFingerprintSHA256: String
    public let proxyJump: SshProxyJumpRuntimeConfig?

    public init(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        proxyJump: SshProxyJumpRuntimeConfig? = nil
    ) {
        self.config = config
        self.secret = secret
        self.expectedFingerprintSHA256 = expectedFingerprintSHA256
        self.proxyJump = proxyJump
    }
}

extension TunnelLiveSessionContext: Sendable {}

public protocol LiveTunnelCoreBridging {
    func checkLocalPortAvailable(_ profile: TunnelProfile) throws
    func startLiveLocalTunnelRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus
    func startLiveLocalTunnelRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus
    func pollLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus
    func closeLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus
    func stopTunnelRuntime(state: TunnelState) throws -> TunnelState
}

public extension LiveTunnelCoreBridging {
    func startLiveLocalTunnelRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus {
        throw SshRuntimeError.Transport(message: "ProxyJump tunnel runtime is not supported by this bridge")
    }
}

public struct CoreLiveTunnelBridge: LiveTunnelCoreBridging {
    public init() {}

    public func checkLocalPortAvailable(_ profile: TunnelProfile) throws {
        try CoreBridge.checkTunnelLocalPortAvailable(profile)
    }

    public func startLiveLocalTunnelRuntime(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        expectedFingerprintSHA256: String,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus {
        try CoreBridge.startLiveLocalTunnelRuntime(
            config: config,
            secret: secret,
            expectedFingerprintSHA256: expectedFingerprintSHA256,
            profile: profile
        )
    }

    public func startLiveLocalTunnelRuntimeWithProxyJump(
        config: SshConnectionConfig,
        secret: SshAuthSecret,
        proxyJump: SshProxyJumpRuntimeConfig,
        profile: TunnelProfile
    ) throws -> TunnelRuntimeStatus {
        try CoreBridge.startLiveLocalTunnelRuntimeWithProxyJump(
            config: config,
            secret: secret,
            proxyJump: proxyJump,
            profile: profile
        )
    }

    public func pollLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus {
        try CoreBridge.pollLiveTunnelRuntime(profileID: profileID)
    }

    public func closeLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus {
        try CoreBridge.closeLiveTunnelRuntime(profileID: profileID)
    }

    public func stopTunnelRuntime(state: TunnelState) throws -> TunnelState {
        try CoreBridge.stopTunnelRuntime(state: state)
    }
}

public protocol TunnelRuntimeBridging {
    func captureLiveSessionContext() -> TunnelLiveSessionContext?
    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus
    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus
    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus
    func poll(profileID: String) throws -> TunnelRuntimeStatus
    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus
}

public extension TunnelRuntimeBridging {
    func captureLiveSessionContext() -> TunnelLiveSessionContext? {
        nil
    }

    func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        try start(profile: profile)
    }

    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        try start(profile: record.profile)
    }
}

public struct CoreBridgeTunnelRuntimeBridge: TunnelRuntimeBridging {
    private let liveSessionContextProvider: () -> TunnelLiveSessionContext?
    private let liveBridge: LiveTunnelCoreBridging
    private let endpointSessionResolver: TunnelEndpointSessionResolving?
    private let endpointContextBuilder: TunnelLiveSessionContextBuilding?
    private let databasePathProvider: () throws -> String

    public init(
        liveSessionContextProvider: @escaping () -> TunnelLiveSessionContext? = { nil },
        liveBridge: LiveTunnelCoreBridging = CoreLiveTunnelBridge(),
        endpointSessionResolver: TunnelEndpointSessionResolving? = nil,
        endpointContextBuilder: TunnelLiveSessionContextBuilding? = nil,
        databasePathProvider: @escaping () throws -> String = { try StacioPaths().databaseURL.path }
    ) {
        self.liveSessionContextProvider = liveSessionContextProvider
        self.liveBridge = liveBridge
        self.endpointSessionResolver = endpointSessionResolver
        self.endpointContextBuilder = endpointContextBuilder
        self.databasePathProvider = databasePathProvider
    }

    public func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus {
        try start(profile: profile, context: liveSessionContextProvider())
    }

    public func captureLiveSessionContext() -> TunnelLiveSessionContext? {
        liveSessionContextProvider()
    }

    public func start(
        profile: TunnelProfile,
        liveSessionContext: TunnelLiveSessionContext?
    ) throws -> TunnelRuntimeStatus {
        try start(profile: profile, context: liveSessionContext)
    }

    public func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        let endpointSessionID = record.endpointSessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let context: TunnelLiveSessionContext?
        if let endpointSessionID, !endpointSessionID.isEmpty {
            guard endpointSessionResolver != nil, endpointContextBuilder != nil else {
                throw TunnelEndpointSessionResolutionError.missingSession
            }
            guard let endpointContext = try makeLiveSessionContext(fromEndpointSessionID: endpointSessionID) else {
                throw TunnelEndpointSessionResolutionError.missingSession
            }
            context = endpointContext
        } else {
            context = liveSessionContextProvider()
        }
        return try start(profile: record.profile, context: context)
    }

    private func start(profile: TunnelProfile, context: TunnelLiveSessionContext?) throws -> TunnelRuntimeStatus {
        guard let context else {
            try liveBridge.checkLocalPortAvailable(profile)
            return TunnelRuntimeStatus(
                profileId: profile.id,
                state: .failed,
                message: "missing_live_session_context"
            )
        }

        StacioLogStore.shared.append(
            level: .info,
            category: "Tunnel",
            message: "tunnel.start.request profile=\(profile.id) ssh=\(context.config.host):\(context.config.port) proxyJump=\(context.proxyJump != nil) kind=\(profile.kind) local=\(profile.localHost):\(profile.localPort) remote=\(profile.remoteHost):\(profile.remotePort)"
        )
        if let proxyJump = context.proxyJump {
            return try liveBridge.startLiveLocalTunnelRuntimeWithProxyJump(
                config: context.config,
                secret: context.secret,
                proxyJump: proxyJump,
                profile: profile
            )
        }
        return try liveBridge.startLiveLocalTunnelRuntime(
            config: context.config,
            secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            profile: profile
        )
    }

    private func makeLiveSessionContext(fromEndpointSessionID endpointSessionID: String?) throws -> TunnelLiveSessionContext? {
        guard let endpointSessionID = endpointSessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpointSessionID.isEmpty
        else {
            return nil
        }
        guard let endpointSessionResolver, let endpointContextBuilder else {
            return nil
        }

        let session = try endpointSessionResolver.resolveEndpointSession(id: endpointSessionID)
        let databasePath = try databasePathProvider()
        let configJSON = try? CoreBridge.getSessionConfigJSON(databasePath: databasePath, id: session.id)
        let config = try Self.sshConfig(
            for: session,
            connectTimeoutMs: SSHConnectionDefaults.connectTimeoutMs(fromConfigJSON: configJSON)
        )
        return try endpointContextBuilder.makeTunnelLiveSessionContext(
            config: config,
            databasePath: databasePath
        )
    }

    private static func sshConfig(
        for session: SessionRecord,
        connectTimeoutMs: UInt32?
    ) throws -> SshConnectionConfig {
        let normalizedProtocol = session.protocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedProtocol == "ssh" || normalizedProtocol == "sftp" || normalizedProtocol == "scp" else {
            throw TunnelEndpointSessionResolutionError.unsupportedProtocol(session.protocol)
        }
        guard session.port > 0, session.port <= UInt32(UInt16.max) else {
            throw TunnelEndpointSessionResolutionError.invalidPort(session.port)
        }

        let host = session.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = session.username?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SshConnectionConfig(
            host: host,
            port: UInt16(session.port),
            username: username?.isEmpty == false ? username! : NSUserName(),
            authMethod: sshAuthMethod(for: session),
            connectTimeoutMs: connectTimeoutMs ?? SSHConnectionDefaults.fastConnectTimeoutMs
        )
    }

    private static func sshAuthMethod(for session: SessionRecord) -> SshAuthMethod {
        let credentialID = session.credentialId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let privateKeyPath = session.privateKeyPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !privateKeyPath.isEmpty {
            return .privateKey(
                keyPath: privateKeyPath,
                passphraseRef: credentialID.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        if let credentialID, !credentialID.isEmpty {
            return .password(credentialRef: credentialID)
        }
        return .agent
    }

    public func poll(profileID: String) throws -> TunnelRuntimeStatus {
        try liveBridge.pollLiveTunnelRuntime(profileID: profileID)
    }

    public func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus {
        if state == .running || state == .starting {
            return try liveBridge.closeLiveTunnelRuntime(profileID: profile.id)
        }
        let stopped = try liveBridge.stopTunnelRuntime(state: state)
        return TunnelRuntimeStatus(profileId: profile.id, state: stopped, message: TunnelRow.label(for: stopped))
    }
}

@MainActor
public final class TunnelsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    public let tableView = StacioDeleteKeyTableView()

    private let titleLabel = NSTextField(labelWithString: L10n.Tunnels.title)
    private let engineLabel = NSTextField(labelWithString: L10n.Tunnels.engine)
    private let emptyLabel = NSTextField(labelWithString: L10n.Tunnels.empty)
    private let diagnosticLabel = NSTextField(wrappingLabelWithString: "")
    private var diagnosticHeightConstraint: NSLayoutConstraint?
    private var columnLayoutSignature: [CGFloat] = []
    private let managementStrip = NSStackView()
    private let tunnelContextMenu = NSMenu(title: "SSH 隧道")
    private var rows: [TunnelRow] = []
    private let runtimeBridge: TunnelRuntimeBridging
    private let profileStore: TunnelProfileStoring?
    private let profileEditor: TunnelProfileEditing
    private let deletionConfirmation: TunnelProfileDeletionConfirming
    private let endpointSessionStore: TunnelEndpointSessionStoring?
    private let maxAutomaticReconnectAttempts: Int
    private var activeTunnelIDs = Set<String>()
    private var manuallyStoppedTunnelIDs = Set<String>()
    private var automaticReconnectAttemptsByTunnelID: [String: Int] = [:]
    private var automaticReconnectWorkItemsByTunnelID: [String: DispatchWorkItem] = [:]
    private var pollTimer: Timer?
    private var quickAddPopover: NSPopover?

    public init(
        runtimeBridge: TunnelRuntimeBridging = CoreBridgeTunnelRuntimeBridge(),
        profileStore: TunnelProfileStoring? = nil,
        profileEditor: TunnelProfileEditing? = nil,
        deletionConfirmation: TunnelProfileDeletionConfirming? = nil,
        endpointSessionStore: TunnelEndpointSessionStoring? = nil,
        maxAutomaticReconnectAttempts: Int = 10
    ) {
        self.runtimeBridge = runtimeBridge
        self.profileStore = profileStore
        self.profileEditor = profileEditor ?? AppKitTunnelProfileEditor()
        self.deletionConfirmation = deletionConfirmation ?? AppKitTunnelProfileDeletionConfirmation()
        self.endpointSessionStore = endpointSessionStore ?? Self.makeDefaultEndpointSessionStore()
        self.maxAutomaticReconnectAttempts = max(0, maxAutomaticReconnectAttempts)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    deinit {
        pollTimer?.invalidate()
        automaticReconnectWorkItemsByTunnelID.values.forEach { $0.cancel() }
    }

    public var tunnelCount: Int {
        rows.count
    }

    public var runningTunnelCount: Int {
        rows.filter(\.isRunning).count
    }

    public var engineSummaryText: String {
        engineLabel.stringValue
    }

    public var visibleTextSnapshot: String {
        var values = [titleLabel.stringValue, engineLabel.stringValue]
        if rows.isEmpty {
            values.append(emptyLabel.stringValue)
        }
        values.append(contentsOf: rows.flatMap(\.visibleValues))
        return values.joined(separator: "\n")
    }

    public var tunnelActionLabels: [String] {
        rows.map(\.actionLabel)
    }

    public var tunnelManagementActionLabels: [String] {
        managementStrip.arrangedSubviews.compactMap { view in
            (view as? NSButton)?.accessibilityLabel()
        }
    }

    public var tunnelManagementActionEnabledStates: [Bool] {
        managementStrip.arrangedSubviews.compactMap { view in
            (view as? NSButton)?.isEnabled
        }
    }

    public var tunnelTrafficTextsForTesting: [String] {
        rows.map(\.trafficText)
    }

    public var tunnelStatusIndicatorStyleNamesForTesting: [String] {
        rows.map { $0.statusIndicatorStyle.name }
    }

    public var quickAddPopoverAccessibilityIdentifierForTesting: String? {
        quickAddPopover?.contentViewController?.view.accessibilityIdentifier()
    }

    public func performTunnelActionForTesting(at index: Int) {
        guard let button = tunnelActionButtonForTesting(at: index) else {
            return
        }
        button.performClick(nil)
    }

    /// Invokes the same start/stop path as the rendered action button without
    /// requiring an attached AppKit window. This keeps inspector/workbench
    /// integration tests deterministic while the button-specific helper above
    /// continues to cover table-cell target/action wiring.
    public func performTunnelActionDirectlyForTesting(at index: Int) {
        guard rows.indices.contains(index) else {
            return
        }
        if rows[index].isRunning {
            stopTunnel(at: index)
        } else {
            startTunnel(at: index)
        }
    }

    /// Returns the action button from the table cell that AppKit would render.
    /// Keeping this path on the table view catches regressions in cell reuse,
    /// target/action wiring, and narrow-column layout.
    public func tunnelActionButtonForTesting(at index: Int) -> NSButton? {
        guard rows.indices.contains(index),
              let column = tableView.tableColumns.firstIndex(where: {
                  $0.identifier.rawValue == "action"
              }),
              let cell = tableView.view(
                  atColumn: column,
                  row: index,
                  makeIfNecessary: true
              ) as? TunnelActionCellView
        else {
            return nil
        }
        return cell.actionButtonForTesting
    }

    public func performTunnelManagementActionForTesting(_ label: String) {
        guard let button = managementStrip.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: {
            $0.accessibilityLabel() == label
        }) else {
            return
        }
        performTunnelManagementAction(button)
    }

    public func presentQuickAddTunnelPopoverForTesting() {
        let anchor = managementStrip.arrangedSubviews.first ?? view
        showQuickAddTunnelPopover(anchor: anchor)
    }

    public func performQuickAddTunnelForTesting(
        kind: TunnelKind,
        localPort: String,
        target: String,
        remark: String
    ) {
        guard let result = TunnelQuickAddProfileBuilder.makeResult(
            kind: kind,
            localPortText: localPort,
            targetText: target,
            remarkText: remark,
            existingProfiles: rows.map(\.profile)
        ) else {
            return
        }
        quickAddPopover?.close()
        saveProfileAndRefresh(result, startAfterSave: true)
    }

    public func tunnelContextMenuTitlesForTesting(row: Int) -> [String] {
        makeTunnelContextMenu(forRow: row)?.items.map(\.title) ?? []
    }

    public func performTunnelContextMenuActionForTesting(row: Int, title: String) {
        guard let item = makeTunnelContextMenu(forRow: row)?.items.first(where: { $0.title == title }) else {
            return
        }
        performTunnelContextAction(item)
    }

    public func selectTunnelRowsForTesting(_ indexes: IndexSet) {
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        updateManagementActionState()
    }

    public override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.applyInspectorContentSurface(container)

        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = StacioDesignSystem.theme.primaryTextColor
        titleLabel.setAccessibilityIdentifier("Stacio.Tunnels.title")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        engineLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        engineLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        engineLabel.translatesAutoresizingMaskIntoConstraints = false

        managementStrip.orientation = .horizontal
        managementStrip.alignment = .centerY
        managementStrip.spacing = 4
        managementStrip.translatesAutoresizingMaskIntoConstraints = false

        // Keep the complete row within the narrow inspector; horizontal scrolling is disabled.
        tableView.addTableColumn(makeColumn(identifier: "kind", title: "类型", width: 42))
        tableView.addTableColumn(makeColumn(identifier: "local", title: "本地", width: 58))
        tableView.addTableColumn(makeColumn(identifier: "remote", title: "远端", width: 62))
        tableView.addTableColumn(makeColumn(identifier: "status", title: "状态", width: 42))
        tableView.addTableColumn(makeColumn(identifier: "detail", title: "详情", width: 70))
        tableView.addTableColumn(makeColumn(identifier: "action", title: "操作", width: 38))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        // Widths are recalculated from the viewport in viewDidLayout. Letting
        // AppKit apply a second uniform autoresize pass can shrink endpoint
        // columns after our calculation and hide otherwise available text.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 42
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.deleteSelectionHandler = { [weak self] in
            guard let self, self.selectedTunnelIndexes.isEmpty == false else { return false }
            self.deleteSelectedTunnelProfiles()
            return true
        }
        tunnelContextMenu.delegate = self
        tableView.menu = tunnelContextMenu
        tableView.setAccessibilityIdentifier("Stacio.Tunnels.table")
        tableView.setAccessibilityLabel(L10n.Tunnels.table)
        StacioDesignSystem.styleTable(tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(engineLabel)
        container.addSubview(managementStrip)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        diagnosticLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        diagnosticLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        diagnosticLabel.isSelectable = true
        diagnosticLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticLabel.setAccessibilityIdentifier("Stacio.Tunnels.fullDiagnostic")
        container.addSubview(diagnosticLabel)
        diagnosticHeightConstraint = diagnosticLabel.heightAnchor.constraint(equalToConstant: 0)
        diagnosticHeightConstraint?.isActive = true

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),

            engineLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            engineLabel.trailingAnchor.constraint(lessThanOrEqualTo: managementStrip.leadingAnchor, constant: -8),
            engineLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            managementStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            managementStrip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: diagnosticLabel.topAnchor, constant: -8),
            diagnosticLabel.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 4),
            diagnosticLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -4),
            diagnosticLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16)
        ])

        updateManagementStrip()
        updateEmptyState()
        restoreProfilesFromStore()
        view = container
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layoutTunnelTableColumns()
        layoutFullDiagnostic()
    }

    private func layoutTunnelTableColumns() {
        guard let scrollView = tableView.enclosingScrollView else {
            return
        }
        let availableWidth = scrollView.contentView.bounds.width
        guard availableWidth > 0, tableView.tableColumns.count == 6 else {
            return
        }

        // The table is the scroll view's document view. Without explicitly
        // sizing it to the viewport, AppKit keeps its initial 312pt document
        // width and every column remains at its tiny setup width.
        if abs(tableView.frame.width - availableWidth) > 0.5 {
            tableView.setFrameSize(NSSize(
                width: availableWidth,
                height: max(tableView.frame.height, scrollView.contentView.bounds.height)
            ))
        }

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func width(_ identifier: String, padding: CGFloat, minimum: CGFloat) -> CGFloat {
            max(minimum, rows.map {
                ceil(($0.value(for: identifier) as NSString).size(withAttributes: [.font: font]).width) + padding
            }.max() ?? minimum)
        }
        // Allocate room for complete addresses before giving the remainder to
        // diagnostics. Fractions alone truncate short IPv4 addresses while
        // wasting space in the type, status and action columns.
        let preferred = [
            width("kind", padding: 27, minimum: 52),
            min(260, width("local", padding: 16, minimum: 88)),
            min(260, width("remote", padding: 16, minimum: 88)),
            width("status", padding: 16, minimum: 52),
            CGFloat(84), CGFloat(40)
        ]
        let signature = [availableWidth] + preferred
        guard signature != columnLayoutSignature else { return }
        columnLayoutSignature = signature
        var columnWidths = preferred
        let preferredTotal = preferred.reduce(0, +)
        if preferredTotal <= availableWidth {
            columnWidths[4] += availableWidth - preferredTotal
        } else {
            let minimums: [CGFloat] = [40, 40, 40, 40, 40, 38]
            let flexible = preferredTotal - minimums.reduce(0, +)
            let fraction = max(0, (availableWidth - minimums.reduce(0, +)) / flexible)
            columnWidths = zip(preferred, minimums).map { desired, minimum in
                minimum + (desired - minimum) * fraction
            }
        }
        for (column, width) in zip(tableView.tableColumns, columnWidths) {
            column.width = width
        }
    }

    private func updateFullDiagnostic() {
        let selectedRow = selectedTunnelIndexes.first.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
        let row = selectedRow ?? rows.first(where: { $0.state == .failed })
        guard let row, row.state == .failed else {
            diagnosticLabel.stringValue = ""
            diagnosticLabel.isHidden = true
            diagnosticHeightConstraint?.constant = 0
            return
        }
        let route: String
        switch row.profile.kind {
        case .remote:
            route = "远端监听 \(row.value(for: "remote")) → 本机目标 \(row.value(for: "local"))"
        case .local:
            route = "本机监听 \(row.value(for: "local")) → 远端目标 \(row.value(for: "remote"))"
        case .dynamic:
            route = "本机 SOCKS 监听 \(row.value(for: "local"))"
        }
        diagnosticLabel.stringValue = "\(route)\n\(row.detailText)"
        diagnosticLabel.isHidden = false
        layoutFullDiagnostic()
    }

    private func layoutFullDiagnostic() {
        guard !diagnosticLabel.isHidden else { return }
        let width = max(1, view.bounds.width - 24)
        diagnosticLabel.preferredMaxLayoutWidth = width
        let text = NSAttributedString(string: diagnosticLabel.stringValue, attributes: [
            .font: diagnosticLabel.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        ])
        diagnosticHeightConstraint?.constant = ceil(text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height) + 4
    }

    public func setTunnelProfiles(_ profiles: [TunnelProfile]) {
        setTunnelProfileRecords(
            profiles.map { profile in
                TunnelProfileRecord(profile: profile, sessionId: nil, endpointSessionId: nil)
            }
        )
    }

    public func setTunnelProfileRecords(_ records: [TunnelProfileRecord]) {
        let existingRowsByID = rows.reduce(into: [String: TunnelRow]()) { result, row in
            if result[row.profile.id] == nil {
                result[row.profile.id] = row
            }
        }
        // Normalize legacy records before any dictionary or row construction.
        // Duplicate IDs otherwise either crash Dictionary initialization or
        // render multiple rows that all control the same runtime.
        var normalizedRecords = [TunnelProfileRecord]()
        var seenRecordIDs = Set<String>()
        for record in records where seenRecordIDs.insert(record.profile.id).inserted {
            normalizedRecords.append(record)
        }
        let recordIDs = Set(normalizedRecords.map { $0.profile.id })
        let incomingRecordsByID = normalizedRecords.reduce(into: [String: TunnelProfileRecord]()) {
            result,
            record in
            result[record.profile.id] = record
        }
        // A persisted edit can arrive while the old runtime is still alive.
        // Tear down any runtime whose complete record changed (including its
        // SSH endpoint binding) before replacing the rows, otherwise the old
        // listener can keep a port occupied while the UI shows "已停止".
        let staleRuntimeRows = activeTunnelIDs.compactMap { profileID -> TunnelRow? in
            guard let row = existingRowsByID[profileID],
                  incomingRecordsByID[profileID] != row.record
            else {
                return nil
            }
            return row
        }
        var failedReloadRows = [String: TunnelRow]()
        for row in staleRuntimeRows {
            let profileID = row.profile.id
            cancelAutomaticReconnect(for: profileID)
            automaticReconnectAttemptsByTunnelID.removeValue(forKey: profileID)
            do {
                let status = try runtimeBridge.stop(profile: row.profile, state: row.state)
                if status.profileId != profileID {
                    StacioLogStore.shared.append(
                        level: .error,
                        category: "Tunnel",
                        message: "tunnel.reload.stop_mismatch expected=\(profileID) actual=\(status.profileId)"
                    )
                    failedReloadRows[profileID] = row.updated(
                        state: .failed,
                        detail: "隧道停止状态不匹配：\(status.profileId)"
                    )
                    continue
                }
            } catch {
                StacioLogStore.shared.append(
                    level: .error,
                    category: "Tunnel",
                        message: "tunnel.reload.stop_failed profile=\(profileID) diagnostic=\(TunnelDiagnosticRedactor.redact(error))"
                    )
                    failedReloadRows[profileID] = row.updated(
                        state: .failed,
                        detail: "停止旧隧道失败：\(TunnelDiagnosticRedactor.redact(error))"
                    )
                    continue
            }
            activeTunnelIDs.remove(profileID)
        }
        let retainedIDs = Set(failedReloadRows.keys)
        let displayRecords = normalizedRecords + failedReloadRows.values
            .filter { !recordIDs.contains($0.profile.id) }
            .map(\.record)
        let displayRecordIDs = Set(displayRecords.map { $0.profile.id })
        let survivingActiveTunnelIDs = Set(displayRecords.compactMap { record -> String? in
            guard activeTunnelIDs.contains(record.profile.id),
                  (existingRowsByID[record.profile.id]?.record == record || retainedIDs.contains(record.profile.id))
            else {
                return nil
            }
            return record.profile.id
        })
        let endpointSessionIDs = Set(displayRecords.compactMap(\.endpointSessionId))
        let endpointTitlesByID: [String: String]
        if endpointSessionIDs.isEmpty {
            endpointTitlesByID = [:]
        } else {
            endpointTitlesByID = availableEndpointSessions().reduce(into: [:]) { result, endpoint in
                // Session IDs should be unique, but preserving the first title
                // keeps a malformed/legacy database from crashing the table view.
                if endpointSessionIDs.contains(endpoint.id), result[endpoint.id] == nil {
                    result[endpoint.id] = endpoint.title
                }
            }
        }
        rows = displayRecords.map { record in
            if let failedRow = failedReloadRows[record.profile.id] {
                return failedRow
            }
            let endpointTitle = record.endpointSessionId.flatMap { endpointTitlesByID[$0] }
            guard survivingActiveTunnelIDs.contains(record.profile.id),
                  let existingRow = existingRowsByID[record.profile.id]
            else {
                return TunnelRow(record: record, endpointTitle: endpointTitle)
            }
            return TunnelRow(
                record: record,
                state: existingRow.state,
                detailText: existingRow.rawDetailText,
                endpointTitle: endpointTitle ?? existingRow.endpointTitle
            )
        }
        activeTunnelIDs = survivingActiveTunnelIDs
        manuallyStoppedTunnelIDs.formIntersection(displayRecordIDs)
        automaticReconnectAttemptsByTunnelID = automaticReconnectAttemptsByTunnelID.filter { displayRecordIDs.contains($0.key) }
        for tunnelID in Array(automaticReconnectWorkItemsByTunnelID.keys)
            where !displayRecordIDs.contains(tunnelID)
        {
            cancelAutomaticReconnect(for: tunnelID)
        }
        refreshTunnelPolling()
        tableView.reloadData()
        layoutTunnelTableColumns()
        updateEmptyState()
        updateManagementActionState()
    }

    public func reloadTunnelProfilesFromStore() throws {
        guard let profileStore else {
            return
        }
        setTunnelProfileRecords(try profileStore.listProfileRecords())
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateManagementActionState()
        updateFullDiagnostic()
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else {
            return nil
        }

        let columnIdentifier = tableColumn.identifier.rawValue
        let identifier = NSUserInterfaceItemIdentifier("TunnelCell.\(columnIdentifier)")
        if columnIdentifier == "kind" {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TunnelKindCellView
                ?? TunnelKindCellView()
            cell.identifier = identifier
            cell.configure(row: rows[row])
            return cell
        }
        if columnIdentifier == "detail" {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TunnelDetailCellView
                ?? TunnelDetailCellView()
            cell.identifier = identifier
            cell.configure(row: rows[row])
            return cell
        }
        if columnIdentifier == "remote" {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TunnelRemoteEndpointCellView
                ?? TunnelRemoteEndpointCellView()
            cell.identifier = identifier
            cell.configure(row: rows[row])
            return cell
        }
        if columnIdentifier == "action" {
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TunnelActionCellView
                ?? TunnelActionCellView()
            cell.identifier = identifier
            cell.configure(button: makeActionButton(row: rows[row]))
            return cell
        }

        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = StacioDesignSystem.theme.primaryTextColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.stringValue = rows[row].value(for: columnIdentifier)
        textField.toolTip = textField.stringValue
        cell.textField = textField

        if textField.superview == nil {
            cell.addSubview(textField)
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        return cell
    }

    private func makeColumn(identifier: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = min(width, 40)
        column.resizingMask = .userResizingMask
        return column
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !rows.isEmpty
        updateFullDiagnostic()
        tableView.superview?.needsLayout = true
    }

    private func updateManagementStrip() {
        managementStrip.arrangedSubviews.forEach { view in
            managementStrip.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for action in TunnelManagementAction.allCases {
            managementStrip.addArrangedSubview(makeManagementButton(action: action))
        }
        updateManagementActionState()
    }

    private func makeManagementButton(action: TunnelManagementAction) -> NSButton {
        let button = NSButton(
            image: managementImage(for: action),
            target: self,
            action: #selector(performTunnelManagementAction(_:))
        )
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = action.label
        button.setAccessibilityLabel(action.label)
        button.identifier = NSUserInterfaceItemIdentifier(action.identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleIconButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }

    private func updateManagementActionState() {
        let selectedCount = selectedTunnelIndexes.count
        for button in managementStrip.arrangedSubviews.compactMap({ $0 as? NSButton }) {
            switch button.accessibilityLabel() {
            case TunnelManagementAction.add.label:
                button.isEnabled = true
            case TunnelManagementAction.edit.label:
                button.isEnabled = selectedCount == 1
            case TunnelManagementAction.delete.label:
                button.isEnabled = selectedCount > 0
            default:
                button.isEnabled = false
            }
        }
    }

    private func makeActionButton(row: TunnelRow) -> NSButton {
        let label = row.actionLabel
        let button = NSButton(
            image: actionImage(named: label),
            target: self,
            action: #selector(performTunnelAction(_:))
        )
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        let endpoint = row.endpointTitle
            ?? runtimeBridge.captureLiveSessionContext().map {
                "当前 SSH 会话 · \($0.config.host):\($0.config.port)"
            }
            ?? "未绑定 SSH 会话"
        button.toolTip = "\(label) · \(endpoint)"
        button.setAccessibilityHelp("\(label) 当前隧道：\(endpoint)")
        button.setAccessibilityLabel(label)
        button.identifier = NSUserInterfaceItemIdentifier(row.profile.id)
        button.translatesAutoresizingMaskIntoConstraints = false
        StacioDesignSystem.styleIconButton(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])
        return button
    }

    @objc private func performTunnelManagementAction(_ sender: NSButton) {
        guard sender.isEnabled,
              let label = sender.accessibilityLabel(),
              let action = TunnelManagementAction(label: label)
        else {
            return
        }

        switch action {
        case .add:
            showQuickAddTunnelPopover(anchor: sender)
        case .edit:
            editSelectedTunnelProfile()
        case .delete:
            deleteSelectedTunnelProfiles()
        }
    }

    @objc private func performTunnelAction(_ sender: NSButton) {
        guard let tunnelID = sender.identifier?.rawValue,
              let index = rows.firstIndex(where: { $0.profile.id == tunnelID })
        else {
            return
        }

        if rows[index].isRunning {
            stopTunnel(at: index)
        } else {
            startTunnel(at: index)
        }
    }

    private func startTunnel(at index: Int) {
        manuallyStoppedTunnelIDs.remove(rows[index].profile.id)
        cancelAutomaticReconnect(for: rows[index].profile.id)
        automaticReconnectAttemptsByTunnelID.removeValue(forKey: rows[index].profile.id)
        do {
            let status = try runtimeBridge.start(record: rows[index].record)
            StacioLogStore.shared.append(
                level: status.state == .failed ? .error : .info,
                category: "Tunnel",
                message: "tunnel.start.result profile=\(rows[index].profile.id) kind=\(rows[index].profile.kind) local=\(rows[index].profile.localHost):\(rows[index].profile.localPort) remote=\(rows[index].profile.remoteHost):\(rows[index].profile.remotePort) state=\(status.state) diagnostic=\(RuntimeDiagnosticFormatter.userMessage(status.message))"
            )
            applyRuntimeStatus(status, toRowAt: index)
        } catch {
            let code: String
            if case let SshRuntimeError.Transport(message) = error,
               message.hasPrefix("SSH_REMOTE_FORWARD_FAILED:"), message.contains("Session(-32)") {
                code = "SSH_REQUEST_DENIED(-32)"
            } else {
                code = "unspecified"
            }
            StacioLogStore.shared.append(
                level: .error,
                category: "Tunnel",
                message: "tunnel.start.failed profile=\(rows[index].profile.id) kind=\(rows[index].profile.kind) local=\(rows[index].profile.localHost):\(rows[index].profile.localPort) remote=\(rows[index].profile.remoteHost):\(rows[index].profile.remotePort) code=\(code) diagnostic=\(TunnelDiagnosticRedactor.redact(error))"
            )
            rows[index] = rows[index].updated(
                state: .failed,
                detail: TunnelDiagnosticRedactor.redact(error)
            )
            activeTunnelIDs.remove(rows[index].profile.id)
            refreshTunnelPolling()
        }
        reloadRowsAfterAction()
    }

    private func stopTunnel(at index: Int) {
        manuallyStoppedTunnelIDs.insert(rows[index].profile.id)
        cancelAutomaticReconnect(for: rows[index].profile.id)
        automaticReconnectAttemptsByTunnelID.removeValue(forKey: rows[index].profile.id)
        do {
            let status = try runtimeBridge.stop(profile: rows[index].profile, state: rows[index].state)
            applyRuntimeStatus(status, toRowAt: index)
            activeTunnelIDs.remove(rows[index].profile.id)
            refreshTunnelPolling()
        } catch {
            rows[index] = rows[index].updated(
                state: .failed,
                detail: TunnelDiagnosticRedactor.redact(error)
            )
            activeTunnelIDs.remove(rows[index].profile.id)
            refreshTunnelPolling()
        }
        reloadRowsAfterAction()
    }

    private func applyRuntimeStatus(_ status: TunnelRuntimeStatus, toRowAt index: Int) {
        let profileID = rows[index].profile.id
        guard status.profileId == profileID else {
            rows[index] = rows[index].updated(
                state: .failed,
                detail: "隧道状态不匹配：\(status.profileId)"
            )
            activeTunnelIDs.remove(profileID)
            activeTunnelIDs.remove(status.profileId)
            refreshTunnelPolling()
            return
        }

        rows[index] = rows[index].updated(state: status.state, detail: status.message)
        if status.state == .running {
            manuallyStoppedTunnelIDs.remove(status.profileId)
            automaticReconnectAttemptsByTunnelID.removeValue(forKey: status.profileId)
            cancelAutomaticReconnect(for: status.profileId)
        } else if let reconnect = TunnelReconnectStatus(status.message),
                  !manuallyStoppedTunnelIDs.contains(status.profileId) {
            guard reconnect.attempt <= maxAutomaticReconnectAttempts else {
                rows[index] = rows[index].updated(
                    state: .failed,
                    detail: "已断开，自动重连超过 \(maxAutomaticReconnectAttempts) 次。"
                )
                activeTunnelIDs.remove(status.profileId)
                automaticReconnectAttemptsByTunnelID.removeValue(forKey: status.profileId)
                cancelAutomaticReconnect(for: status.profileId)
                refreshTunnelPolling()
                return
            }
            rows[index] = rows[index].updated(state: .starting, detail: reconnectDisplayText(attempt: reconnect.attempt))
            scheduleAutomaticReconnect(forRowAt: index, attempt: reconnect.attempt)
        } else if status.state == .failed || status.state == .stopped {
            cancelAutomaticReconnect(for: status.profileId)
            automaticReconnectAttemptsByTunnelID.removeValue(forKey: status.profileId)
        }
        updatePollingRegistration(for: status)
    }

    func pollActiveTunnels() {
        guard !activeTunnelIDs.isEmpty else {
            refreshTunnelPolling()
            return
        }

        var didUpdate = false
        // Polling can remove failed or deleted IDs. Iterate over a snapshot so
        // a disconnect during this pass never mutates the collection being
        // traversed.
        for profileID in Array(activeTunnelIDs) {
            guard let index = rows.firstIndex(where: { $0.profile.id == profileID }) else {
                activeTunnelIDs.remove(profileID)
                didUpdate = true
                continue
            }

            do {
                let status = try runtimeBridge.poll(profileID: profileID)
                guard status.profileId == profileID else {
                    continue
                }
                applyRuntimeStatus(status, toRowAt: index)
            } catch {
                StacioLogStore.shared.append(
                    level: .error,
                    category: "Tunnel",
                    message: "tunnel.poll.failed profile=\(profileID) diagnostic=\(TunnelDiagnosticRedactor.redact(error))"
                )
                rows[index] = rows[index].updated(
                    state: .failed,
                    detail: TunnelDiagnosticRedactor.redact(error)
                )
                activeTunnelIDs.remove(profileID)
            }
            didUpdate = true
        }

        refreshTunnelPolling()
        if didUpdate {
            reloadRowsAfterAction()
        }
    }

    private func updatePollingRegistration(for status: TunnelRuntimeStatus) {
        switch status.state {
        case .running, .starting:
            activeTunnelIDs.insert(status.profileId)
        case .stopped, .failed:
            activeTunnelIDs.remove(status.profileId)
        }
        refreshTunnelPolling()
    }

    private func scheduleAutomaticReconnect(forRowAt index: Int, attempt: Int) {
        guard rows.indices.contains(index) else {
            return
        }
        let profileID = rows[index].profile.id
        guard maxAutomaticReconnectAttempts > 0,
              attempt <= maxAutomaticReconnectAttempts,
              automaticReconnectWorkItemsByTunnelID[profileID] == nil,
              !manuallyStoppedTunnelIDs.contains(profileID)
        else {
            if attempt > maxAutomaticReconnectAttempts {
                rows[index] = rows[index].updated(
                    state: .failed,
                    detail: "已断开，自动重连超过 \(maxAutomaticReconnectAttempts) 次。"
                )
                activeTunnelIDs.remove(profileID)
                refreshTunnelPolling()
            }
            return
        }

        automaticReconnectAttemptsByTunnelID[profileID] = attempt
        let delay = RemoteSSHReconnectPolicy.automaticDelaySeconds(forAttempt: attempt)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.automaticReconnectWorkItemsByTunnelID.removeValue(forKey: profileID)
            self.performAutomaticReconnect(profileID: profileID, attempt: attempt)
        }
        automaticReconnectWorkItemsByTunnelID[profileID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performAutomaticReconnect(profileID: String, attempt: Int) {
        guard !manuallyStoppedTunnelIDs.contains(profileID),
              automaticReconnectAttemptsByTunnelID[profileID] == attempt,
              let index = rows.firstIndex(where: { $0.profile.id == profileID })
        else {
            return
        }

        do {
            let status = try runtimeBridge.start(record: rows[index].record)
            applyRuntimeStatus(status, toRowAt: index)
        } catch {
            let nextAttempt = attempt + 1
            if nextAttempt > maxAutomaticReconnectAttempts {
                rows[index] = rows[index].updated(
                    state: .failed,
                    detail: "已断开，自动重连超过 \(maxAutomaticReconnectAttempts) 次。"
                )
                activeTunnelIDs.remove(profileID)
                automaticReconnectAttemptsByTunnelID.removeValue(forKey: profileID)
                refreshTunnelPolling()
            } else {
                automaticReconnectAttemptsByTunnelID[profileID] = nextAttempt
                rows[index] = rows[index].updated(
                    state: .starting,
                    detail: reconnectDisplayText(attempt: nextAttempt)
                )
                activeTunnelIDs.insert(profileID)
                scheduleAutomaticReconnect(forRowAt: index, attempt: nextAttempt)
            }
        }
        reloadRowsAfterAction()
    }

    private func cancelAutomaticReconnect(for profileID: String) {
        automaticReconnectWorkItemsByTunnelID.removeValue(forKey: profileID)?.cancel()
    }

    private func reconnectDisplayText(attempt: Int) -> String {
        "重连中…（第\(attempt)次）"
    }

    private func refreshTunnelPolling() {
        if activeTunnelIDs.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }

        guard pollTimer == nil else {
            return
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.pollActiveTunnels()
            }
        }
    }

    private func showQuickAddTunnelPopover(anchor: NSView) {
        quickAddPopover?.close()
        let controller = TunnelQuickAddViewController(existingProfiles: rows.map(\.profile))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.onCreate = { [weak self, weak popover] result in
            popover?.close()
            self?.saveProfileAndRefresh(result, startAfterSave: true)
        }
        quickAddPopover = popover
        if anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
    }

    private func editSelectedTunnelProfile() {
        guard selectedTunnelIndexes.count == 1,
              let index = selectedTunnelIndexes.first
        else {
            return
        }
        editTunnel(at: index)
    }

    private func editTunnel(at index: Int) {
        guard rows.indices.contains(index),
              let result = profileEditor.makeTunnelProfile(
                existingRecord: rows[index].record,
                existingProfiles: rows.map(\.profile),
                endpointSessions: availableEndpointSessions(),
                parentWindow: view.window
              )
        else { return }
        saveProfileAndRefresh(result)
    }

    private func deleteSelectedTunnelProfiles() {
        let profiles = selectedTunnelIndexes.compactMap { index in
            rows.indices.contains(index) ? rows[index].profile : nil
        }
        deleteTunnelProfiles(profiles)
    }

    private func deleteTunnel(at index: Int) {
        guard rows.indices.contains(index) else { return }
        deleteTunnelProfiles([rows[index].profile])
    }

    private func deleteTunnelProfiles(_ profiles: [TunnelProfile]) {
        guard !profiles.isEmpty,
              deletionConfirmation.shouldDeleteTunnelProfiles(profiles, parentWindow: view.window)
        else {
            return
        }

        do {
            try stopRunningTunnelsBeforeDeletion(profiles)
            if let profileStore {
                for profile in profiles {
                    try profileStore.deleteProfile(id: profile.id)
                }
                try reloadTunnelProfilesFromStore()
            } else {
                let ids = Set(profiles.map(\.id))
                setTunnelProfileRecords(rows.map(\.record).filter { !ids.contains($0.profile.id) })
            }
        } catch {
            showProfileStoreError(error)
        }
    }

    private func stopRunningTunnelsBeforeDeletion(_ profiles: [TunnelProfile]) throws {
        let profileIDs = Set(profiles.map(\.id))
        for index in rows.indices where profileIDs.contains(rows[index].profile.id) && rows[index].isRunning {
            do {
                let profileID = rows[index].profile.id
                let status = try runtimeBridge.stop(profile: rows[index].profile, state: rows[index].state)
                guard status.profileId == profileID else {
                    rows[index] = rows[index].updated(
                        state: .failed,
                        detail: "隧道状态不匹配：\(status.profileId)"
                    )
                    refreshTunnelPolling()
                    reloadRowsAfterAction()
                    throw TunnelRuntimeStatusMismatchError(
                        expectedProfileID: profileID,
                        actualProfileID: status.profileId
                    )
                }
                rows[index] = rows[index].updated(state: status.state, detail: status.message)
                activeTunnelIDs.remove(profileID)
            } catch {
                rows[index] = rows[index].updated(
                    state: .failed,
                    detail: TunnelDiagnosticRedactor.redact(error)
                )
                refreshTunnelPolling()
                reloadRowsAfterAction()
                throw error
            }
        }
        refreshTunnelPolling()
    }

    private func saveProfileAndRefresh(
        _ result: TunnelProfileEditResult,
        startAfterSave: Bool = false
    ) {
        let record = TunnelProfileRecord(
            profile: result.profile,
            sessionId: rows.first(where: { $0.profile.id == result.profile.id })?.record.sessionId,
            endpointSessionId: result.endpointSessionID
        )
        do {
            if let profileStore {
                try profileStore.saveProfileRecord(record)
                try reloadTunnelProfilesFromStore()
            } else {
                var records = rows.map(\.record)
                if let index = records.firstIndex(where: { $0.profile.id == result.profile.id }) {
                    records[index] = record
                } else {
                    records.append(record)
                }
                setTunnelProfileRecords(records)
            }
            if startAfterSave,
               let index = rows.firstIndex(where: { $0.profile.id == result.profile.id }) {
                startTunnel(at: index)
            }
        } catch {
            showProfileStoreError(error)
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === tunnelContextMenu else {
            return
        }
        menu.removeAllItems()
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : selectedTunnelIndexes.first ?? -1
        populateTunnelContextMenu(menu, row: row)
    }

    private func makeTunnelContextMenu(forRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else {
            return nil
        }
        let menu = NSMenu(title: "SSH 隧道")
        populateTunnelContextMenu(menu, row: row)
        return menu
    }

    private func populateTunnelContextMenu(_ menu: NSMenu, row: Int) {
        guard rows.indices.contains(row) else {
            return
        }
        let tunnel = rows[row]
        let startStopAction: TunnelContextAction = tunnel.isRunning ? .stop : .start
        addTunnelContextItem(startStopAction.title, action: startStopAction, row: row, to: menu)
        addTunnelContextItem("编辑隧道", action: .edit, row: row, to: menu)
        menu.addItem(.separator())
        addTunnelContextItem("复制 SSH 隧道命令", action: .copyCommand, row: row, to: menu)
        menu.addItem(.separator())
        addTunnelContextItem("删除隧道", action: .delete, row: row, to: menu)
    }

    private func addTunnelContextItem(
        _ title: String,
        action: TunnelContextAction,
        row: Int,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(performTunnelContextAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = action.rawValue
        item.representedObject = rows[row].profile.id
        menu.addItem(item)
    }

    @objc private func performTunnelContextAction(_ sender: NSMenuItem) {
        guard let profileID = sender.representedObject as? String,
              let row = rows.firstIndex(where: { $0.profile.id == profileID }),
              let action = TunnelContextAction(rawValue: sender.tag)
        else {
            return
        }

        switch action {
        case .start:
            startTunnel(at: row)
        case .stop:
            stopTunnel(at: row)
        case .edit:
            editTunnel(at: row)
        case .copyCommand:
            copyTunnelCommand(for: row)
        case .delete:
            deleteTunnel(at: row)
        }
    }

    private func copyTunnelCommand(for row: Int) {
        guard rows.indices.contains(row) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sshTunnelCommand(for: rows[row].record), forType: .string)
    }

    private func sshTunnelCommand(for record: TunnelProfileRecord) -> String {
        let profile = record.profile
        let destination = sshDestination(for: record)
        switch profile.kind {
        case .local:
            return "ssh -L \(localForwardArgument(for: profile)) \(destination)"
        case .remote:
            return "ssh -R \(remoteForwardArgument(for: profile)) \(destination)"
        case .dynamic:
            return "ssh -D \(dynamicForwardArgument(for: profile)) \(destination)"
        }
    }

    private func sshDestination(for record: TunnelProfileRecord) -> String {
        guard let endpointSessionID = record.endpointSessionId,
              let endpoint = availableEndpointSessions().first(where: { $0.id == endpointSessionID })
        else {
            return "user@host"
        }
        if let username = endpoint.username, !username.isEmpty {
            return "\(username)@\(endpoint.host)"
        }
        return endpoint.host
    }

    private func localForwardArgument(for profile: TunnelProfile) -> String {
        let bindPrefix = isDefaultLocalBind(profile.localHost) ? "" : "\(profile.localHost):"
        return "\(bindPrefix)\(profile.localPort):\(profile.remoteHost):\(profile.remotePort)"
    }

    private func remoteForwardArgument(for profile: TunnelProfile) -> String {
        let remoteBind = isWildcardRemoteBind(profile.remoteHost)
            ? "\(profile.remotePort)"
            : "\(profile.remoteHost):\(profile.remotePort)"
        return "\(remoteBind):\(profile.localHost):\(profile.localPort)"
    }

    private func dynamicForwardArgument(for profile: TunnelProfile) -> String {
        isDefaultLocalBind(profile.localHost) ? "\(profile.localPort)" : "\(profile.localHost):\(profile.localPort)"
    }

    private func isDefaultLocalBind(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host.isEmpty
    }

    private func isWildcardRemoteBind(_ host: String) -> Bool {
        host.isEmpty || host == "0.0.0.0" || host == "::"
    }

    private func restoreProfilesFromStore() {
        do {
            try reloadTunnelProfilesFromStore()
        } catch {
            showProfileStoreError(error)
        }
    }

    private func showProfileStoreError(_ error: Error) {
        engineLabel.stringValue = "\(L10n.Tunnels.engine) - \(TunnelDiagnosticRedactor.redact(error))"
    }

    private func availableEndpointSessions() -> [TunnelEndpointSession] {
        guard let endpointSessionStore else {
            return []
        }

        do {
            let folderSessions = try endpointSessionStore.listFolders().flatMap { folder in
                try endpointSessionStore.listSessions(folderID: folder.id).compactMap {
                    TunnelEndpointSession(session: $0, folderName: folder.name)
                }
            }
            let rootSessions = try endpointSessionStore.listSessions(folderID: nil)
            return TunnelEndpointSession.selectable(from: rootSessions) + folderSessions
        } catch {
            return []
        }
    }

    private static func makeDefaultEndpointSessionStore() -> TunnelEndpointSessionStoring? {
        guard let paths = try? StacioPaths() else {
            return nil
        }
        return CoreBridgeSessionSidebarStore(databasePath: paths.databaseURL.path)
    }

    private func reloadRowsAfterAction() {
        tableView.reloadData()
        layoutTunnelTableColumns()
        updateEmptyState()
        updateManagementActionState()
    }

    private func actionImage(named label: String) -> NSImage {
        if #available(macOS 11.0, *) {
            let symbolName = label == L10n.Tunnels.start ? "play.fill" : "stop.fill"
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label) {
                return image
            }
        }
        return NSImage(size: NSSize(width: 14, height: 14))
    }

    private func managementImage(for action: TunnelManagementAction) -> NSImage {
        if #available(macOS 11.0, *) {
            if let image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.label) {
                return image
            }
        }
        return NSImage(size: NSSize(width: 14, height: 14))
    }

    private var selectedTunnelIndexes: [Int] {
        tableView.selectedRowIndexes.filter { rows.indices.contains($0) }
    }
}

private struct TunnelRuntimeStatusMismatchError: LocalizedError {
    let expectedProfileID: String
    let actualProfileID: String

    var errorDescription: String? {
        "隧道状态不匹配：\(actualProfileID)"
    }
}

private struct TunnelReconnectStatus {
    let attempt: Int

    init?(_ message: String) {
        let parts = message.split(separator: " ").map(String.init)
        guard parts.first == "reconnecting" else {
            return nil
        }
        let values = parts.dropFirst().compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else {
                return nil
            }
            return (pair[0], pair[1])
        }
        .reduce(into: [String: String]()) { result, pair in
            if result[pair.0] == nil {
                result[pair.0] = pair.1
            }
        }
        guard let attemptText = values["attempt"],
              let attempt = Int(attemptText)
        else {
            return nil
        }
        self.attempt = attempt
    }
}

private enum TunnelManagementAction: CaseIterable {
    case add
    case edit
    case delete

    init?(label: String) {
        guard let action = Self.allCases.first(where: { $0.label == label }) else {
            return nil
        }
        self = action
    }

    var label: String {
        switch self {
        case .add: L10n.Tunnels.add
        case .edit: L10n.Tunnels.edit
        case .delete: L10n.Tunnels.delete
        }
    }

    var identifier: String {
        switch self {
        case .add: "Stacio.Tunnels.addProfile"
        case .edit: "Stacio.Tunnels.editProfile"
        case .delete: "Stacio.Tunnels.deleteProfile"
        }
    }

    var symbolName: String {
        switch self {
        case .add: "plus"
        case .edit: "pencil"
        case .delete: "trash"
        }
    }
}

private enum TunnelContextAction: Int {
    case start = 1
    case stop
    case edit
    case copyCommand
    case delete

    var title: String {
        switch self {
        case .start: L10n.Tunnels.start
        case .stop: L10n.Tunnels.stop
        case .edit: L10n.Tunnels.edit
        case .copyCommand: "复制 SSH 隧道命令"
        case .delete: L10n.Tunnels.delete
        }
    }
}

private final class TunnelKindCellView: NSTableCellView {
    private let dotView = TunnelStatusDotView()
    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(row: TunnelRow) {
        titleField.stringValue = row.value(for: "kind")
        titleField.toolTip = titleField.stringValue
        dotView.configure(style: row.statusIndicatorStyle)
        textField = titleField
    }

    private func setup() {
        dotView.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleField.textColor = StacioDesignSystem.theme.primaryTextColor
        titleField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dotView)
        addSubview(titleField)

        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),

            titleField.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 5),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class TunnelDetailCellView: NSTableCellView {
    private let detailField = NSTextField(labelWithString: "")
    private let trafficField = NSTextField(labelWithString: "")
    private var detailToTrafficConstraint: NSLayoutConstraint!
    private var detailToEdgeConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(row: TunnelRow) {
        let detail = row.value(for: "detail")
        detailField.stringValue = detail.hasPrefix("SSH 服务器拒绝远端监听。") ? "服务器拒绝监听" : detail
        detailField.toolTip = detail
        // A dash is only the empty traffic placeholder. Hiding it gives the
        // diagnostic the full cell width instead of truncating it around a
        // value that conveys no information.
        trafficField.stringValue = row.trafficText == "—" ? "" : row.trafficText
        trafficField.isHidden = row.trafficText == "—"
        detailToTrafficConstraint.isActive = !trafficField.isHidden
        detailToEdgeConstraint.isActive = trafficField.isHidden
        trafficField.toolTip = row.trafficText
        trafficField.setAccessibilityIdentifier("Stacio.Tunnels.traffic.\(row.profile.id)")
        textField = detailField
    }

    private func setup() {
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1
        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.textColor = StacioDesignSystem.theme.primaryTextColor
        detailField.translatesAutoresizingMaskIntoConstraints = false

        trafficField.lineBreakMode = .byTruncatingMiddle
        trafficField.maximumNumberOfLines = 1
        trafficField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        trafficField.textColor = StacioDesignSystem.theme.secondaryTextColor
        trafficField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(detailField)
        addSubview(trafficField)
        detailToTrafficConstraint = detailField.trailingAnchor.constraint(equalTo: trafficField.leadingAnchor, constant: -4)
        detailToEdgeConstraint = detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)

        NSLayoutConstraint.activate([
            detailField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            detailField.centerYAnchor.constraint(equalTo: centerYAnchor),

            trafficField.leadingAnchor.constraint(greaterThanOrEqualTo: detailField.leadingAnchor, constant: 4),
            trafficField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            trafficField.firstBaselineAnchor.constraint(equalTo: detailField.firstBaselineAnchor)
        ])

        // Keep the diagnostic as the cell's primary text while placing the
        // traffic summary on the same baseline. The traffic field remains
        // separately accessible without creating a second visual row.
        trafficField.alignment = .right
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trafficField.setContentCompressionResistancePriority(.required, for: .horizontal)
        trafficField.setContentHuggingPriority(.required, for: .horizontal)
    }
}

private final class TunnelRemoteEndpointCellView: NSTableCellView {
    private let targetField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(row: TunnelRow) {
        targetField.stringValue = row.value(for: "remote")
        let role = row.profile.kind == .remote ? "远端监听" : "远端目标"
        targetField.toolTip = row.endpointTitle.map { "SSH 会话 · \($0)\n\(role) · \(targetField.stringValue)" }
            ?? "\(role) · \(targetField.stringValue)"
        targetField.setAccessibilityHelp(targetField.toolTip)
        textField = targetField
    }

    private func setup() {
        targetField.lineBreakMode = .byTruncatingMiddle
        targetField.maximumNumberOfLines = 1
        targetField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        targetField.textColor = StacioDesignSystem.theme.primaryTextColor
        targetField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(targetField)
        NSLayoutConstraint.activate([
            targetField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            targetField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            targetField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class TunnelActionCellView: NSTableCellView {
    private var actionButton: NSButton?
    private var actionConstraints: [NSLayoutConstraint] = []

    var actionButtonForTesting: NSButton? {
        actionButton
    }

    func configure(button: NSButton) {
        NSLayoutConstraint.deactivate(actionConstraints)
        actionConstraints.removeAll(keepingCapacity: true)
        actionButton?.removeFromSuperview()
        actionButton = button
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        actionConstraints = [
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ]
        NSLayoutConstraint.activate(actionConstraints)
    }
}

private final class TunnelStatusDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func configure(style: TunnelStatusIndicatorStyle) {
        setAccessibilityLabel(style.accessibilityLabel)
        toolTip = style.accessibilityLabel
        StacioDesignSystem.setLayerBackgroundColor(self, color: style.color)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }
}

private enum TunnelStatusIndicatorStyle {
    case running
    case connecting
    case stopped
    case failed

    var name: String {
        switch self {
        case .running: "running"
        case .connecting: "connecting"
        case .stopped: "stopped"
        case .failed: "failed"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .running: "运行中"
        case .connecting: "连接中/重连中"
        case .stopped: "已停止"
        case .failed: "错误"
        }
    }

    var color: NSColor {
        switch self {
        case .running: StacioDesignSystem.theme.successColor
        case .connecting: StacioDesignSystem.theme.warningColor
        case .stopped: StacioDesignSystem.theme.secondaryTextColor
        case .failed: StacioDesignSystem.theme.dangerColor
        }
    }
}

private struct TunnelRuntimeTraffic: Equatable {
    let uploadBytes: UInt64
    let downloadBytes: UInt64

    var displayText: String {
        "↑ \(Self.byteCount(uploadBytes))  ↓ \(Self.byteCount(downloadBytes))"
    }

    static func parse(_ rawDetail: String) -> TunnelRuntimeTraffic? {
        let parts = rawDetail.split(separator: " ").map(String.init)
        let values = parts.compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else {
                return nil
            }
            return (pair[0], pair[1])
        }
        .reduce(into: [String: String]()) { result, pair in
            if result[pair.0] == nil {
                result[pair.0] = pair.1
            }
        }
        guard let uploadBytes = UInt64(values["client_to_remote_bytes"] ?? ""),
              let downloadBytes = UInt64(values["remote_to_client_bytes"] ?? "")
        else {
            return nil
        }
        return TunnelRuntimeTraffic(uploadBytes: uploadBytes, downloadBytes: downloadBytes)
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        if bytes < 1_024 {
            return "\(bytes) B"
        }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1_024.0
        var unitIndex = 0
        while value >= 1_024.0 && unitIndex < units.count - 1 {
            value /= 1_024.0
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }
}

private struct TunnelRow {
    let record: TunnelProfileRecord
    let state: TunnelState
    let rawDetailText: String
    let detailText: String
    let trafficText: String
    let endpointTitle: String?

    init(
        record: TunnelProfileRecord,
        state: TunnelState = .stopped,
        detailText: String = L10n.Tunnels.ready,
        endpointTitle: String? = nil
    ) {
        self.record = record
        self.state = state
        self.endpointTitle = endpointTitle
        rawDetailText = detailText
        self.detailText = L10n.Tunnels.detail(detailText)
        trafficText = TunnelRuntimeTraffic.parse(detailText)?.displayText ?? "—"
    }

    var profile: TunnelProfile {
        record.profile
    }

    var visibleValues: [String] {
        [kindText, localEndpoint, remoteEndpoint, statusText, detailText, trafficText]
    }

    var actionLabel: String {
        isRunning ? L10n.Tunnels.stop : L10n.Tunnels.start
    }

    var isRunning: Bool {
        state == .running || state == .starting
    }

    func value(for columnIdentifier: String) -> String {
        switch columnIdentifier {
        case "kind": kindText
        case "local": localEndpoint
        case "remote": remoteEndpoint
        case "status": statusText
        case "detail": detailText
        default: ""
        }
    }

    func updated(state: TunnelState, detail: String) -> TunnelRow {
        TunnelRow(record: record, state: state, detailText: detail, endpointTitle: endpointTitle)
    }

    var statusIndicatorStyle: TunnelStatusIndicatorStyle {
        switch state {
        case .running: .running
        case .starting: .connecting
        case .stopped: .stopped
        case .failed: .failed
        }
    }

    static func label(for state: TunnelState) -> String {
        switch state {
        case .stopped: "已停止"
        case .starting: "启动中"
        case .running: "运行中"
        case .failed: "失败"
        }
    }

    private var kindText: String {
        switch profile.kind {
        case .local: "本地"
        case .remote: "远端"
        case .dynamic: "动态"
        }
    }

    private var localEndpoint: String {
        "\(profile.localHost):\(profile.localPort)"
    }

    private var remoteEndpoint: String {
        if profile.kind == .dynamic {
            return "由 SOCKS 客户端指定"
        }
        return "\(profile.remoteHost):\(profile.remotePort)"
    }

    private var statusText: String {
        Self.label(for: state)
    }
}

private enum TunnelDiagnosticRedactor {
    static func redact(_ error: Error) -> String {
        if let resolutionError = error as? TunnelEndpointSessionResolutionError {
            switch resolutionError {
            case .missingSession:
                return "找不到隧道绑定的 SSH/SCP 会话，请重新选择会话端点。"
            case let .unsupportedProtocol(protocolName):
                return "\(protocolName) 会话不支持启动 SSH 隧道，请选择 SSH 或 SCP 会话。"
            case .missingCredential:
                return "隧道绑定的会话缺少凭据，请在会话设置中重新保存认证信息。"
            case .invalidPort:
                return "隧道绑定的会话端口无效，请重新编辑会话。"
            }
        }
        if error as? KeychainCredentialError == .notFound {
            return "隧道绑定的会话缺少凭据，请在会话设置中重新保存认证信息。"
        }
        if error as? SSHConnectionCoordinatorError == .missingPasswordSecret {
            return "隧道绑定的会话缺少凭据，请在会话设置中重新保存认证信息。"
        }
        return RuntimeDiagnosticFormatter.userMessage(for: error)
    }
}
