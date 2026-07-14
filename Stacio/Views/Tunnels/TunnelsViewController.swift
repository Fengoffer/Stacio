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
    func pollLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus
    func closeLiveTunnelRuntime(profileID: String) throws -> TunnelRuntimeStatus
    func stopTunnelRuntime(state: TunnelState) throws -> TunnelState
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
    func start(profile: TunnelProfile) throws -> TunnelRuntimeStatus
    func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus
    func poll(profileID: String) throws -> TunnelRuntimeStatus
    func stop(profile: TunnelProfile, state: TunnelState) throws -> TunnelRuntimeStatus
}

public extension TunnelRuntimeBridging {
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

    public func start(record: TunnelProfileRecord) throws -> TunnelRuntimeStatus {
        let context = try liveSessionContextProvider()
            ?? makeLiveSessionContext(fromEndpointSessionID: record.endpointSessionId)
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
        guard normalizedProtocol == "ssh" || normalizedProtocol == "scp" else {
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
    public let tableView = NSTableView()

    private let titleLabel = NSTextField(labelWithString: L10n.Tunnels.title)
    private let engineLabel = NSTextField(labelWithString: L10n.Tunnels.engine)
    private let emptyLabel = NSTextField(labelWithString: L10n.Tunnels.empty)
    private let managementStrip = NSStackView()
    private let actionStrip = NSStackView()
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
        actionStrip.arrangedSubviews.compactMap { view in
            (view as? NSButton)?.accessibilityLabel()
        }
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
        guard actionStrip.arrangedSubviews.indices.contains(index),
              let button = actionStrip.arrangedSubviews[index] as? NSButton
        else {
            return
        }
        performTunnelAction(button)
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
        copyTunnelCommandFromMenu(item)
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

        actionStrip.orientation = .horizontal
        actionStrip.alignment = .centerY
        actionStrip.spacing = 6
        actionStrip.translatesAutoresizingMaskIntoConstraints = false

        tableView.addTableColumn(makeColumn(identifier: "kind", title: "类型", width: 48))
        tableView.addTableColumn(makeColumn(identifier: "local", title: "本地", width: 68))
        tableView.addTableColumn(makeColumn(identifier: "remote", title: "远端", width: 76))
        tableView.addTableColumn(makeColumn(identifier: "status", title: "状态", width: 44))
        tableView.addTableColumn(makeColumn(identifier: "detail", title: "详情", width: 82))
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
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
        container.addSubview(actionStrip)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),

            engineLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            engineLabel.trailingAnchor.constraint(lessThanOrEqualTo: managementStrip.leadingAnchor, constant: -8),
            engineLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            managementStrip.trailingAnchor.constraint(equalTo: actionStrip.leadingAnchor, constant: -8),
            managementStrip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            actionStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            actionStrip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

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

    public func setTunnelProfiles(_ profiles: [TunnelProfile]) {
        setTunnelProfileRecords(
            profiles.map { profile in
                TunnelProfileRecord(profile: profile, sessionId: nil, endpointSessionId: nil)
            }
        )
    }

    public func setTunnelProfileRecords(_ records: [TunnelProfileRecord]) {
        let existingRowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.profile.id, $0) })
        let recordIDs = Set(records.map { $0.profile.id })
        let survivingActiveTunnelIDs = Set(records.compactMap { record -> String? in
            guard activeTunnelIDs.contains(record.profile.id),
                  existingRowsByID[record.profile.id]?.record == record
            else {
                return nil
            }
            return record.profile.id
        })
        rows = records.map { record in
            guard survivingActiveTunnelIDs.contains(record.profile.id),
                  let existingRow = existingRowsByID[record.profile.id]
            else {
                return TunnelRow(record: record)
            }
            return TunnelRow(
                record: record,
                state: existingRow.state,
                detailText: existingRow.rawDetailText
            )
        }
        activeTunnelIDs = survivingActiveTunnelIDs
        manuallyStoppedTunnelIDs.formIntersection(recordIDs)
        automaticReconnectAttemptsByTunnelID = automaticReconnectAttemptsByTunnelID.filter { recordIDs.contains($0.key) }
        for tunnelID in automaticReconnectWorkItemsByTunnelID.keys where !recordIDs.contains(tunnelID) {
            cancelAutomaticReconnect(for: tunnelID)
        }
        refreshTunnelPolling()
        tableView.reloadData()
        updateActionStrip()
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
    }

    private func updateActionStrip() {
        actionStrip.arrangedSubviews.forEach { view in
            actionStrip.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for row in rows {
            actionStrip.addArrangedSubview(makeActionButton(row: row))
        }
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
        button.toolTip = label
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
            applyRuntimeStatus(status, toRowAt: index)
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
        for profileID in activeTunnelIDs {
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
              let index = selectedTunnelIndexes.first,
              rows.indices.contains(index),
              let result = profileEditor.makeTunnelProfile(
                existingRecord: rows[index].record,
                existingProfiles: rows.map(\.profile),
                endpointSessions: availableEndpointSessions(),
                parentWindow: view.window
              )
        else {
            return
        }
        saveProfileAndRefresh(result)
    }

    private func deleteSelectedTunnelProfiles() {
        let profiles = selectedTunnelIndexes.compactMap { index in
            rows.indices.contains(index) ? rows[index].profile : nil
        }
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
                    activeTunnelIDs.remove(profileID)
                    activeTunnelIDs.remove(status.profileId)
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
                activeTunnelIDs.remove(rows[index].profile.id)
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
        let item = NSMenuItem(
            title: "复制SSH 隧道命令",
            action: #selector(copyTunnelCommandFromMenu(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = row
        menu.addItem(item)
    }

    @objc private func copyTunnelCommandFromMenu(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int,
              rows.indices.contains(row)
        else {
            return
        }
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
                try endpointSessionStore.listSessions(folderID: folder.id)
            }
            let rootSessions = try endpointSessionStore.listSessions(folderID: nil)
            return TunnelEndpointSession.selectable(from: rootSessions + folderSessions)
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
        updateActionStrip()
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
        let values = Dictionary(
            uniqueKeysWithValues: parts.dropFirst().compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else {
                    return nil
                }
                return (pair[0], pair[1])
            }
        )
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(row: TunnelRow) {
        detailField.stringValue = row.value(for: "detail")
        detailField.toolTip = detailField.stringValue
        trafficField.stringValue = row.trafficText
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

        NSLayoutConstraint.activate([
            detailField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            detailField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detailField.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            trafficField.leadingAnchor.constraint(equalTo: detailField.leadingAnchor),
            trafficField.trailingAnchor.constraint(equalTo: detailField.trailingAnchor),
            trafficField.topAnchor.constraint(equalTo: detailField.bottomAnchor, constant: 1),
            trafficField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -3)
        ])
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
        let values = Dictionary(
            uniqueKeysWithValues: parts.compactMap { part -> (String, String)? in
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else {
                    return nil
                }
                return (pair[0], pair[1])
            }
        )
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

    init(record: TunnelProfileRecord, state: TunnelState = .stopped, detailText: String = L10n.Tunnels.ready) {
        self.record = record
        self.state = state
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
        TunnelRow(record: record, state: state, detailText: detail)
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
